#Requires -Version 5.1
<#
Diagnoses why a Pimax Crystal shows "disconnected" in Pimax Play when no
hardware was changed and it worked previously. Inspects the Windows-side
state that actually breaks the DisplayPort + USB link: Pimax services/
processes, PnP devices in an error state, whether the headset display is
enumerated, recent GPU driver / Windows updates, USB selective suspend,
Fast Startup, and recent USB/PnP disconnect events in the System log.

Run from an *elevated* PowerShell prompt:
    powershell -ExecutionPolicy Bypass -File .\Check-PimaxConnection.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Write-Section($title) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    Write-Host $title -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkGray
}

function Write-Result {
    param(
        [string]$Label,
        [string]$Value,
        [ValidateSet('OK','WARN','FAIL','INFO')][string]$Status = 'INFO'
    )
    $color = switch ($Status) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    '{0,-38} {1}' -f ($Label + ':'), $Value | Write-Host -ForegroundColor $color
}

$findings = [System.Collections.Generic.List[string]]::new()
function Add-Finding([string]$msg) { $findings.Add($msg) }

$isAdmin = ([Security.Principal.WindowsPrincipal] `
           [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'WARNING: not elevated. Event log and some PnP checks will be incomplete. Re-run as Administrator.' -ForegroundColor Yellow
}

# ---- Pimax software running -------------------------------------------------
Write-Section 'Pimax software'

$piProcNames = 'PimaxClient','PiServiceLauncher','pi_server','PiServer','PiService','PiTool','PimaxXR','PVRServer','RuntimeSvc'
$running = @()
foreach ($n in $piProcNames) {
    $p = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($p) { $running += $n; Write-Result "Process $n" 'Running' 'OK' }
}
if (-not $running) {
    Write-Result 'Pimax processes' 'NONE running' 'FAIL'
    Add-Finding 'No Pimax runtime process is running. Launch Pimax Play as Administrator. If it is already "open" in the tray but no PimaxClient/pi_server process exists, the service crashed - fully quit it, end any leftover Pimax processes in Task Manager, and relaunch.'
} else {
    # The client UI can run while the underlying server process is dead.
    # Match the actual running names against the server-process patterns;
    # -notmatch on the whole array would return the non-matching elements
    # (a false positive whenever the UI process is up), so filter explicitly.
    $serverUp = @($running | Where-Object { $_ -match 'pi_server|PVRServer|PiServer|RuntimeSvc' })
    if (-not $serverUp) {
        Add-Finding 'Pimax client UI is running but the underlying runtime/server process (pi_server) is not. This is the classic "UI shows disconnected" state. Fully quit Pimax Play, end all Pimax processes in Task Manager, then relaunch as Administrator.'
    } else {
        Write-Result 'Runtime server process' 'Up (pi_server)' 'OK'
    }
}

Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Pimax|PVR' } | ForEach-Object {
    $st = if ($_.Status -eq 'Running') { 'OK' } else { 'WARN' }
    Write-Result "Service $($_.Name)" $_.Status $st
    if ($_.Status -ne 'Running') {
        Add-Finding "Pimax-related service '$($_.Name)' is $($_.Status). Start it: Start-Service '$($_.Name)' (or set it to Automatic in services.msc)."
    }
}

# ---- PnP devices in an error state -----------------------------------------
Write-Section 'Devices in error / disconnected state'

try {
    $bad = Get-PnpDevice -ErrorAction Stop |
           Where-Object { $_.Status -ne 'OK' -and $_.Present -eq $true } |
           Where-Object { $_.Class -in 'USB','Display','Monitor','HIDClass','Unknown','Ports','MEDIA' -or $_.FriendlyName -match 'Pimax|Crystal|VR|HMD|Unknown' }
    if ($bad) {
        foreach ($d in $bad) {
            Write-Result "$($d.Class)" "$($d.FriendlyName) [$($d.Status), code=$($d.ProblemCode)]" 'FAIL'
        }
        Add-Finding 'One or more relevant devices are in an error state. If you see an "Unknown USB Device (Device Descriptor Request Failed)" or a yellow-bang device, that is the Crystal not enumerating - replug its USB into a different rear/motherboard port, avoid hubs and front-panel ports, and try Device Manager > right-click > Uninstall device, then Scan for hardware changes.'
    } else {
        Write-Result 'Error-state devices' 'None found' 'OK'
    }
} catch {
    Write-Result 'Get-PnpDevice' "Error: $_" 'WARN'
}

# Look specifically for anything that names the Crystal / Pimax
try {
    $pimaxDev = Get-PnpDevice -ErrorAction Stop | Where-Object { $_.FriendlyName -match 'Pimax|Crystal' }
    if ($pimaxDev) {
        Write-Section 'Named Pimax devices'
        foreach ($d in $pimaxDev) {
            $st = if ($d.Status -eq 'OK') { 'OK' } else { 'FAIL' }
            Write-Result "$($d.Class)" "$($d.FriendlyName) [$($d.Status)]" $st
        }
    } else {
        Write-Result 'Named Pimax devices' 'None enumerated by Windows' 'WARN'
        Add-Finding 'Windows does not see any device named Pimax/Crystal. The USB side of the headset is not enumerating at all - this points at the USB cable/port or headset power, not software. Try a different rear USB port and confirm the headset has power (status LED).'
    }
} catch { }

# ---- Is the headset display attached? --------------------------------------
Write-Section 'Displays (DisplayPort side)'

try {
    $mons = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction Stop
    Write-Result 'Monitors enumerated' $mons.Count
    $connected = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction SilentlyContinue
    # A connected-but-headset display often shows as a generic PnP monitor.
    Get-CimInstance Win32_DesktopMonitor -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Result 'Desktop monitor' "$($_.Name) ($($_.ScreenWidth)x$($_.ScreenHeight))"
    }
} catch {
    Write-Result 'Monitor WMI' "Error: $_" 'WARN'
}

# NVIDIA-side view of connected displays (the Crystal is a DP display to the GPU)
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $smi) { $d = "$env:SystemRoot\System32\nvidia-smi.exe"; if (Test-Path $d) { $smi = @{ Source = $d } } }
if ($smi) {
    try {
        $disp = & $smi.Source --query-gpu=display_active,display_mode --format=csv,noheader 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Result 'GPU display_active / mode' ($disp -join ' | ') }
    } catch { }
}

# ---- Recent GPU driver / Windows updates (the "worked yesterday" smoking gun)
Write-Section 'Recent driver / OS changes'

try {
    $nv = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
    if ($nv) {
        Write-Result 'NVIDIA driver version' $nv.DriverVersion
        Write-Result 'NVIDIA driver date'    $nv.DriverDate
        if ($nv.DriverDate -and ((Get-Date) - $nv.DriverDate).TotalDays -le 3) {
            Write-Result 'Driver recently changed' 'YES - within 3 days' 'WARN'
            Add-Finding "The NVIDIA driver was installed/updated within the last 3 days ($($nv.DriverDate.ToShortDateString())). A background/Windows-Update driver swap frequently drops the DisplayPort link to a VR HMD until a full reboot. Reboot; if it persists, reinstall the Pimax-recommended driver or do a clean (DDU) driver reinstall."
        }
    }
} catch { Write-Result 'Video controller' "Error: $_" 'WARN' }

try {
    $recentHotfix = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn -and ((Get-Date) - $_.InstalledOn).TotalDays -le 3 }
    if ($recentHotfix) {
        foreach ($h in $recentHotfix) { Write-Result 'Recent update' "$($h.HotFixID) on $($h.InstalledOn.ToShortDateString())" 'WARN' }
        Add-Finding 'Windows installed an update within the last 3 days. Updates can reset USB/display driver state or re-enable USB selective suspend. Reboot fully (see Fast Startup below) before deeper troubleshooting.'
    } else {
        Write-Result 'Windows updates (last 3 days)' 'None' 'OK'
    }
} catch { Write-Result 'Get-HotFix' "Error: $_" 'WARN' }

# ---- USB selective suspend + Fast Startup ----------------------------------
Write-Section 'USB power + Fast Startup'

try {
    $scheme = (powercfg /getactivescheme) -replace '.*GUID:\s*([\w-]+).*', '$1'
    $usbSub = '2a737441-1930-4402-8d77-b2bebba308a3'   # USB settings subgroup
    $usbSel = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'   # USB selective suspend setting
    $out = powercfg /query $scheme $usbSub $usbSel 2>$null
    $acHex = ($out | Select-String 'Current AC Power Setting Index:\s*(0x\w+)').Matches.Groups[1].Value
    if ($acHex) {
        $val = [Convert]::ToInt32($acHex,16)
        Write-Result 'USB selective suspend (AC)' ($(if ($val -eq 0) {'Disabled'} else {'ENABLED'})) ($(if ($val -eq 0) {'OK'} else {'WARN'}))
        if ($val -ne 0) {
            Add-Finding 'USB selective suspend is enabled. Windows can power down the Crystal USB port, presenting as a disconnect. Disable it: powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 ; powercfg /setactive SCHEME_CURRENT. Also uncheck "Allow the computer to turn off this device" on the USB Root Hubs in Device Manager > Power Management.'
        }
    }
} catch { Write-Result 'USB selective suspend' "Could not read: $_" 'WARN' }

try {
    $hiber = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled
    if ($hiber -eq 1) {
        Write-Result 'Fast Startup' 'ENABLED' 'WARN'
        Add-Finding 'Fast Startup is enabled. After a *Shut Down* it leaves USB/DisplayPort in a stale state - a classic cause of "worked yesterday, disconnected today". Either always use Restart (not Shut Down), or disable Fast Startup: Control Panel > Power Options > Choose what the power buttons do > uncheck "Turn on fast startup".'
    } else {
        Write-Result 'Fast Startup' 'Disabled' 'OK'
    }
} catch { Write-Result 'Fast Startup' 'Not readable' 'WARN' }

# ---- Recent USB / PnP disconnect events -------------------------------------
Write-Section 'Recent USB / PnP events (System log, last 24h)'

if ($isAdmin) {
    try {
        $since = (Get-Date).AddHours(-24)
        $evt = Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$since } -ErrorAction Stop |
               Where-Object { $_.ProviderName -match 'Kernel-PnP|USB|nvlddmkm|Display' -and $_.LevelDisplayName -in 'Error','Warning' } |
               Select-Object -First 15
        if ($evt) {
            foreach ($e in $evt) {
                $msg = ($e.Message -split "`n")[0]
                Write-Host ("  {0}  [{1}] {2}" -f $e.TimeCreated.ToString('MM-dd HH:mm'), $e.ProviderName, $msg) -ForegroundColor Gray
            }
            Add-Finding 'There are recent USB/PnP/display errors in the System event log (above). Repeated Kernel-PnP or USB entries around the time it disconnected confirm a physical link drop (cable/port/power) rather than a Pimax software issue. nvlddmkm entries point at the GPU driver/DisplayPort side.'
        } else {
            Write-Result 'Relevant error/warning events' 'None in last 24h' 'OK'
        }
    } catch {
        Write-Result 'Get-WinEvent' "Error: $_" 'WARN'
    }
} else {
    Write-Result 'Event log' 'Skipped (needs Administrator)' 'WARN'
}

# ---- Summary ---------------------------------------------------------------
Write-Section 'Summary'
if ($findings.Count -eq 0) {
    Write-Host 'No software/OS cause detected. If the Crystal still shows disconnected:' -ForegroundColor Green
    Write-Host '  1. Power-cycle the headset and the DP/USB at the PC end.' -ForegroundColor Gray
    Write-Host '  2. Try the other DisplayPort output on the 4090.' -ForegroundColor Gray
    Write-Host '  3. Reinstall/repair Pimax Play, then reboot.' -ForegroundColor Gray
} else {
    for ($i = 0; $i -lt $findings.Count; $i++) {
        Write-Host ("{0}. {1}" -f ($i + 1), $findings[$i]) -ForegroundColor Yellow
        Write-Host ''
    }
}
