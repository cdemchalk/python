#Requires -Version 5.1
<#
.SYNOPSIS
    Scans a Windows PC for hardware resources and OS-level settings that
    govern VR performance, with thresholds tuned for the Pimax Crystal
    driven at its highest refresh / resolution.

.DESCRIPTION
    The Pimax Crystal renders 2880x2880 per eye (QLED, local dimming) at up
    to 120 Hz (160 Hz on Crystal Super) over DisplayPort 1.4 + DSC. That is
    ~16.6 million native pixels per frame before any SteamVR supersampling,
    which is why "highest framerate" on this headset is almost always GPU
    bound. This script inventories the parts of the machine that decide
    whether you hit that ceiling, flags the ones most likely to be the
    bottleneck, and prints a numbered, prioritized list of fixes.

    It is READ-ONLY. It changes nothing on the system. Every recommendation
    is printed for you to apply yourself.

.NOTES
    Run from an *elevated* PowerShell prompt for the most complete picture
    (power plan, some driver and firmware queries):

        powershell -ExecutionPolicy Bypass -File .\Get-VRReadiness.ps1

    Save a copy of the report to a file:

        .\Get-VRReadiness.ps1 -ReportPath .\vr-report.txt
#>

[CmdletBinding()]
param(
    [string]$ReportPath
)

$ErrorActionPreference = 'Continue'

# Mirror everything written to the host into a transcript file if asked.
if ($ReportPath) {
    try { Start-Transcript -Path $ReportPath -Force | Out-Null } catch { }
}

# ---- Output helpers (style matches the other scripts in this repo) --------
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
    '{0,-34} {1}' -f ($Label + ':'), $Value | Write-Host -ForegroundColor $color
}

# Findings carry a priority so the summary can sort GPU/RAM ahead of nits.
$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('CRITICAL','HIGH','MEDIUM','LOW')][string]$Priority = 'MEDIUM'
    )
    $findings.Add([pscustomobject]@{ Priority = $Priority; Message = $Message })
}

# ---- Admin check ----------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
           [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ''
Write-Host 'Pimax Crystal - VR Readiness & Resource Report' -ForegroundColor White
Write-Host ('Generated {0}' -f (Get-Date)) -ForegroundColor DarkGray
if (-not $isAdmin) {
    Write-Host 'NOTE: not elevated. Power-plan and some driver checks may be incomplete.' -ForegroundColor Yellow
}

# ===========================================================================
# System overview
# ===========================================================================
Write-Section 'System overview'
try {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $bios= Get-CimInstance Win32_BIOS
    Write-Result 'Machine'        ('{0} {1}' -f $cs.Manufacturer, $cs.Model)
    Write-Result 'Windows'        ('{0} (build {1})' -f $os.Caption, $os.BuildNumber)
    Write-Result 'BIOS version'   ('{0} {1}' -f ($bios.SMBIOSBIOSVersion), ($bios.ReleaseDate))
    $uptime = (Get-Date) - $os.LastBootUpTime
    Write-Result 'Uptime'         ('{0:N1} days' -f $uptime.TotalDays) ($(if ($uptime.TotalDays -gt 7) {'WARN'} else {'INFO'}))
    if ($uptime.TotalDays -gt 7) {
        Add-Finding 'Uptime is over a week. A reboot clears leaked GPU/driver memory and stale background tasks before a VR session.' 'LOW'
    }
    # Win11 build 22000+ ; older Win10 is fine but flag very old builds.
    if ([int]$os.BuildNumber -lt 19041) {
        Add-Finding "Windows build $($os.BuildNumber) is old. Update to a current Windows 10 22H2 or Windows 11 build for the latest WDDM/scheduler improvements that VR relies on." 'MEDIUM'
    }
} catch { Write-Result 'System overview' "Error: $_" 'WARN' }

# ===========================================================================
# GPU  - the single most important component for Crystal high-framerate
# ===========================================================================
Write-Section 'GPU (primary VR bottleneck)'
$primaryGpu = $null
try {
    $gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.AdapterRAM -ne $null -or $_.Name }
    foreach ($g in $gpus) {
        # Win32_VideoController.AdapterRAM is a 32-bit field and caps at 4 GB.
        # Read the true VRAM from the driver registry key instead.
        $vramGB = $null
        try {
            $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
            foreach ($k in (Get-ChildItem $base -ErrorAction SilentlyContinue)) {
                $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
                if ($p.'HardwareInformation.qwMemorySize' -and ($p.DriverDesc -eq $g.Name)) {
                    $vramGB = [math]::Round($p.'HardwareInformation.qwMemorySize' / 1GB, 0)
                    break
                }
            }
        } catch { }
        if (-not $vramGB -and $g.AdapterRAM) { $vramGB = [math]::Round($g.AdapterRAM / 1GB, 0) }

        $isDiscrete = $g.Name -match 'NVIDIA|GeForce|RTX|GTX|Radeon|RX |Arc'
        if ($isDiscrete -and -not $primaryGpu) { $primaryGpu = $g; $primaryVram = $vramGB }

        Write-Result ('GPU') $g.Name ($(if ($isDiscrete) {'OK'} else {'INFO'}))
        Write-Result '  Driver version' $g.DriverVersion
        Write-Result '  Driver date'    $g.DriverDate
        Write-Result '  VRAM'           ("{0} GB" -f $vramGB) ($(if ($vramGB -ge 12) {'OK'} elseif ($vramGB -ge 8) {'WARN'} else {'FAIL'}))

        # Driver age matters: NVIDIA/AMD ship VR-specific fixes constantly.
        if ($g.DriverDate) {
            $age = (Get-Date) - $g.DriverDate
            if ($age.TotalDays -gt 120) {
                Add-Finding ("GPU driver for '$($g.Name)' is $([int]$age.TotalDays) days old. Install the latest Game Ready / Adrenalin driver - VR latency and DSC fixes land here. Use a clean (DDU) install if you have had stutter.") 'MEDIUM'
            }
        }
    }

    if (-not $primaryGpu) {
        Write-Result 'Discrete GPU' 'NONE DETECTED' 'FAIL'
        Add-Finding 'No discrete GPU detected. The Pimax Crystal cannot be driven at playable VR framerates on integrated graphics. A discrete GPU is mandatory.' 'CRITICAL'
    } else {
        # Tier the GPU against Crystal high-framerate expectations.
        $name = $primaryGpu.Name
        $tier = 'UNKNOWN'
        if ($name -match 'RTX\s?(40|50)90|RTX\s?(40|50)80')      { $tier = 'EXCELLENT' }
        elseif ($name -match 'RTX\s?(30)90|RTX\s?(40|50)70|RTX\s?3080') { $tier = 'GOOD' }
        elseif ($name -match 'RTX\s?30(70|60)|RTX\s?20(80|70)|RX\s?6(8|9)00|RX\s?7(7|8|9)00') { $tier = 'MARGINAL' }
        elseif ($name -match 'GTX|RTX\s?20(60)|RTX\s?3050|RX\s?6(5|6)00') { $tier = 'INSUFFICIENT' }

        $tierStatus = switch ($tier) { 'EXCELLENT'{'OK'} 'GOOD'{'OK'} 'MARGINAL'{'WARN'} 'INSUFFICIENT'{'FAIL'} default{'INFO'} }
        Write-Result 'Crystal high-FPS GPU tier' $tier $tierStatus
        switch ($tier) {
            'GOOD'        { Add-Finding "GPU ($name) is solid for the Crystal but native 90-120 Hz at full res usually needs aggressive use of DLSS/Quad-Views, OpenXR Toolkit foveated rendering, and a moderate render-quality (~0.8-1.0x) in Pimax Play. Expect to trade supersampling for framerate." 'HIGH' }
            'MARGINAL'    { Add-Finding "GPU ($name) is below the comfort line for full-res high-FPS on the Crystal. Lower the per-eye render quality in Pimax Play, cap at 72-90 Hz, and lean on DLSS + fixed-foveated rendering. This is very likely your framerate limiter." 'HIGH' }
            'INSUFFICIENT'{ Add-Finding "GPU ($name) is not capable of high-framerate full-res Crystal rendering. This is the primary resource restriction. A RTX 4070-Ti/4080/4090-class card is the realistic path to high FPS." 'CRITICAL' }
            'UNKNOWN'     { Add-Finding "Could not map '$name' to a known VR tier. Compare its raster + VRAM against a RTX 4070 Ti as the practical floor for Crystal high-FPS." 'MEDIUM' }
        }
        if ($primaryVram -and $primaryVram -lt 12) {
            Add-Finding "GPU has only $primaryVram GB VRAM. Crystal's high native resolution plus supersampling can exceed 8-10 GB; 12 GB+ is the comfortable target. Low VRAM shows up as sudden frame-time spikes / texture hitching." 'HIGH'
        }
    }
} catch { Write-Result 'GPU enumeration' "Error: $_" 'WARN' }

# ===========================================================================
# CPU
# ===========================================================================
Write-Section 'CPU'
try {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Write-Result 'Processor'      $cpu.Name
    Write-Result 'Cores / Threads' ('{0} / {1}' -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors) `
                 ($(if ($cpu.NumberOfCores -ge 6) {'OK'} else {'WARN'}))
    Write-Result 'Max clock'      ('{0} MHz' -f $cpu.MaxClockSpeed)
    # Sample current load briefly.
    $load = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    Write-Result 'Current load'   ("{0}%" -f $load) ($(if ($load -lt 30) {'OK'} elseif ($load -lt 60) {'WARN'} else {'FAIL'}))
    if ($cpu.NumberOfCores -lt 6) {
        Add-Finding "CPU has only $($cpu.NumberOfCores) cores. VR runtime + compositor + game want 6+ physical cores; fewer can cause CPU-bound frame drops independent of the GPU." 'MEDIUM'
    }
    if ($load -ge 40) {
        Add-Finding "CPU is at $load% load at idle/desktop. Something is consuming the cores you need for VR - check the background-process section below before blaming the GPU." 'MEDIUM'
    }
} catch { Write-Result 'CPU' "Error: $_" 'WARN' }

# ===========================================================================
# Memory
# ===========================================================================
Write-Section 'Memory (RAM)'
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 0)
    $freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    Write-Result 'Total RAM' ("{0} GB" -f $totalGB) ($(if ($totalGB -ge 32) {'OK'} elseif ($totalGB -ge 16) {'WARN'} else {'FAIL'}))
    Write-Result 'Free RAM'  ("{0} GB" -f $freeGB)

    $sticks = Get-CimInstance Win32_PhysicalMemory
    $channels = ($sticks | Measure-Object).Count
    $speeds = ($sticks | Select-Object -ExpandProperty Speed -Unique) -join '/'
    Write-Result 'Modules'   ("{0} stick(s) @ {1} MT/s" -f $channels, $speeds) ($(if ($channels -ge 2) {'OK'} else {'WARN'}))

    if ($totalGB -lt 16) {
        Add-Finding "Only $totalGB GB RAM. 32 GB is the recommended target for VR; under 16 GB will page to disk and stutter. Add RAM." 'HIGH'
    } elseif ($totalGB -lt 32) {
        Add-Finding "$totalGB GB RAM is the bare minimum. 32 GB is recommended for the Crystal so the OS, SteamVR, Pimax Play and the game are not fighting for memory." 'MEDIUM'
    }
    if ($channels -lt 2) {
        Add-Finding 'Only one RAM module detected = single-channel memory. This roughly halves memory bandwidth and noticeably hurts CPU-side VR frametimes. Install a matched second stick to run dual-channel.' 'HIGH'
    }
} catch { Write-Result 'Memory' "Error: $_" 'WARN' }

# ===========================================================================
# Storage
# ===========================================================================
Write-Section 'Storage'
try {
    $disks = Get-CimInstance Win32_DiskDrive
    foreach ($d in $disks) {
        $media = if ($d.MediaType) { $d.MediaType } else { 'Unknown' }
        $sizeGB = [math]::Round($d.Size / 1GB, 0)
        Write-Result ('Disk') ("{0}  ({1} GB)  {2}" -f $d.Model, $sizeGB, $media)
    }
    # Per-volume free space (system + likely game library drives).
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $freeGB = [math]::Round($_.FreeSpace / 1GB, 0)
        $pct = if ($_.Size) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 0) } else { 0 }
        Write-Result ("Volume {0} free" -f $_.DeviceID) ("{0} GB ({1}%)" -f $freeGB, $pct) `
                     ($(if ($pct -ge 15) {'OK'} elseif ($pct -ge 8) {'WARN'} else {'FAIL'}))
        if ($pct -lt 10) {
            Add-Finding "Volume $($_.DeviceID) is $pct% free. Low free space slows the drive and can stall shader-cache / pagefile writes mid-session. Free up space." 'MEDIUM'
        }
    }
    # SSDs reported as 'Fixed hard disk' by Win32_DiskDrive; try the storage cmdlet for a clearer media type.
    try {
        Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
            Write-Result ("PhysicalDisk media") ("{0}  ->  {1}  ({2})" -f $_.FriendlyName, $_.MediaType, $_.BusType)
            if ($_.MediaType -eq 'HDD') {
                Add-Finding "A spinning HDD ($($_.FriendlyName)) is present. Install VR titles on an NVMe/SSD - HDD load times and in-session streaming cause hitches." 'LOW'
            }
        }
    } catch { }
} catch { Write-Result 'Storage' "Error: $_" 'WARN' }

# ===========================================================================
# Display / DisplayPort path  (Crystal needs DP 1.4 + DSC)
# ===========================================================================
Write-Section 'Display output path'
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $monitors = [System.Windows.Forms.Screen]::AllScreens
    Write-Result 'Active displays' ($monitors.Count)
    Write-Host '  The Crystal connects over DisplayPort 1.4 and REQUIRES DSC to run' -ForegroundColor Gray
    Write-Host '  full resolution at high refresh. Plug it directly into the GPU,' -ForegroundColor Gray
    Write-Host '  not the motherboard and not through most DP/USB-C hubs or KVMs.' -ForegroundColor Gray
    Add-Finding 'Verify the headset DisplayPort cable runs straight from the GPU. MST hubs, DP1.2 cables, and many USB-C dongles silently break DSC and cap refresh rate - a common cause of "stuck at low Hz".' 'MEDIUM'
} catch { Write-Result 'Display output path' "Error: $_" 'WARN' }

# ===========================================================================
# USB controllers  (Crystal data/cameras + dongles want clean USB 3.x)
# ===========================================================================
Write-Section 'USB controllers'
try {
    $usb = Get-CimInstance Win32_USBController
    $hasUsb3 = $false
    foreach ($u in $usb) {
        $is3 = $u.Name -match '3\.\d|USB 3|xHCI|eXtensible'
        if ($is3) { $hasUsb3 = $true }
        Write-Result 'Controller' $u.Name ($(if ($is3) {'OK'} else {'INFO'}))
    }
    if (-not $hasUsb3) {
        Add-Finding 'No USB 3.x / xHCI controller clearly detected. The Crystal expects a USB 3.x port; on a USB 2 port it can fail to start or drop tracking.' 'HIGH'
    }
    Write-Host '  Tip: if you get USB disconnects, move the headset to a USB port wired' -ForegroundColor Gray
    Write-Host '  directly to the motherboard/CPU (rear I/O), and disable USB selective' -ForegroundColor Gray
    Write-Host '  suspend (covered in the Power section).' -ForegroundColor Gray
} catch { Write-Result 'USB controllers' "Error: $_" 'WARN' }

# ===========================================================================
# Power plan  (VR wants no downclocking / no USB suspend)
# ===========================================================================
Write-Section 'Power plan'
try {
    $active = (powercfg /getactivescheme) 2>$null
    Write-Result 'Active scheme' ($active -replace '^.*\(', '(' )
    $isHighPerf = $active -match 'High performance|Ultimate Performance'
    Write-Result 'High/Ultimate performance' ([bool]$isHighPerf) ($(if ($isHighPerf) {'OK'} else {'WARN'}))
    if (-not $isHighPerf) {
        Add-Finding 'Power plan is not High/Ultimate Performance. Balanced can down-clock the CPU mid-frame and cause VR microstutter. Set: powercfg /setactive scheme_min  (High performance), or unlock Ultimate with: powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61' 'MEDIUM'
    }

    # USB selective suspend is a frequent cause of headset dropouts.
    $usbSuspend = (powercfg /q SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226) 2>$null
    if ($usbSuspend -match 'Current AC Power Setting Index:\s*0x0+1') {
        Write-Result 'USB selective suspend (AC)' 'Enabled' 'WARN'
        Add-Finding 'USB selective suspend is enabled. It can power down the headset link mid-session. Disable it in Power Options > USB settings, or for the active plan only.' 'MEDIUM'
    } elseif ($usbSuspend) {
        Write-Result 'USB selective suspend (AC)' 'Disabled' 'OK'
    }
} catch { Write-Result 'Power plan' "Error: $_" 'WARN' }

# ===========================================================================
# Windows graphics / scheduling settings
# ===========================================================================
Write-Section 'Windows graphics settings'

# Hardware-Accelerated GPU Scheduling (HAGS)
try {
    $hags = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction Stop).HwSchMode
    $on = $hags -eq 2
    Write-Result 'HW GPU Scheduling (HAGS)' ($(if ($on) {'On'} else {'Off'})) 'INFO'
    Write-Host '  HAGS effect on VR varies by GPU/driver. If you see stutter, try toggling it' -ForegroundColor Gray
    Write-Host '  (Settings > Display > Graphics > Change default graphics settings) and retest.' -ForegroundColor Gray
} catch { Write-Result 'HW GPU Scheduling (HAGS)' 'Not set (default)' 'INFO' }

# Game Mode
try {
    $gm = (Get-ItemProperty 'HKCU:\Software\Microsoft\GameBar' -Name AutoGameModeEnabled -ErrorAction Stop).AutoGameModeEnabled
    Write-Result 'Game Mode' ($(if ($gm -eq 1) {'On'} else {'Off'})) ($(if ($gm -eq 1) {'OK'} else {'INFO'}))
} catch { Write-Result 'Game Mode' 'Default' 'INFO' }

# Xbox Game Bar / Game DVR background recording steals GPU.
try {
    $dvr = (Get-ItemProperty 'HKCU:\System\GameConfigStore' -Name GameDVR_Enabled -ErrorAction SilentlyContinue).GameDVR_Enabled
    if ($dvr -eq 1) {
        Write-Result 'Game DVR / background capture' 'Enabled' 'WARN'
        Add-Finding 'Game DVR / Xbox Game Bar background recording is on and continuously taxes the GPU. Turn off Settings > Gaming > Captures > "Record what happened" and disable Game Bar.' 'MEDIUM'
    } else {
        Write-Result 'Game DVR / background capture' 'Disabled' 'OK'
    }
} catch { }

# ===========================================================================
# Virtualization-Based Security / Memory Integrity (HVCI)
#   - real VR framerate cost on many systems; security tradeoff noted.
# ===========================================================================
Write-Section 'Memory Integrity / VBS (performance tax)'
try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard `
          -Namespace 'root\Microsoft\Windows\DeviceGuard' -ErrorAction Stop
    $vbsOn = $dg.VirtualizationBasedSecurityStatus -eq 2
    $hvciOn = $dg.SecurityServicesRunning -contains 2
    Write-Result 'VBS running'        ([bool]$vbsOn)  ($(if ($vbsOn) {'WARN'} else {'OK'}))
    Write-Result 'Memory Integrity (HVCI)' ([bool]$hvciOn) ($(if ($hvciOn) {'WARN'} else {'OK'}))
    if ($vbsOn -or $hvciOn) {
        Add-Finding 'VBS / Memory Integrity (HVCI) is active. It can cost a measurable few-percent of CPU/GPU performance that matters when you are framerate-restricted. If you accept the security tradeoff, disable Core Isolation > Memory Integrity (Windows Security > Device Security) and retest. Re-enable if you need it.' 'MEDIUM'
    }
} catch { Write-Result 'Win32_DeviceGuard' "Not available" 'INFO' }

# ===========================================================================
# Thermals (best-effort; real numbers need vendor tools)
# ===========================================================================
Write-Section 'Thermals (best-effort)'
try {
    $tz = Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
    foreach ($z in $tz) {
        $c = [math]::Round(($z.CurrentTemperature / 10) - 273.15, 1)
        Write-Result 'ACPI thermal zone' ("{0} C" -f $c) ($(if ($c -lt 80) {'OK'} elseif ($c -lt 95) {'WARN'} else {'FAIL'}))
    }
    Write-Host '  ACPI zones are coarse. For real CPU/GPU temps under VR load use HWiNFO64' -ForegroundColor Gray
    Write-Host '  and watch for thermal throttling - sustained high temps cap clocks and FPS.' -ForegroundColor Gray
} catch {
    Write-Result 'ACPI thermal zones' 'Not exposed by this firmware' 'INFO'
    Write-Host '  Use HWiNFO64 or GPU-Z to confirm the GPU is not thermal/power throttling' -ForegroundColor Gray
    Write-Host '  during a VR session - that is a hidden framerate limiter.' -ForegroundColor Gray
}

# ===========================================================================
# Background load - what is eating resources right now
# ===========================================================================
Write-Section 'Top background resource consumers'
try {
    Write-Host 'By memory:' -ForegroundColor Gray
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 6 |
        ForEach-Object {
            Write-Result ('  ' + $_.ProcessName) ("{0:N0} MB" -f ($_.WorkingSet64 / 1MB))
        }
    # Flag known resource-heavy background apps people forget are running.
    $hogs = Get-Process | Where-Object {
        $_.ProcessName -match 'Chrome|msedge|Discord|OBS|Spotify|RazerCentral|iCUE|Armoury|GHUB|MSIAfterburner|Brave|firefox'
    } | Select-Object -ExpandProperty ProcessName -Unique
    if ($hogs) {
        Write-Result 'Heavy apps running' ($hogs -join ', ') 'WARN'
        Add-Finding ("Resource-heavy apps are running: $($hogs -join ', '). Browsers and RGB/overlay suites consume GPU and CPU. Close them (and overlays like Discord/GeForce Experience in-game overlay) before a VR session.") 'LOW'
    }
} catch { Write-Result 'Background processes' "Error: $_" 'WARN' }

# ===========================================================================
# VR software stack
# ===========================================================================
Write-Section 'VR software'
$swPaths = @{
    'Pimax Play'  = @("$env:ProgramFiles\Pimax\Pimax Client", "${env:ProgramFiles(x86)}\Pimax")
    'SteamVR'     = @("$env:ProgramFiles(x86)\Steam\steamapps\common\SteamVR", "$env:ProgramFiles\Steam\steamapps\common\SteamVR")
    'OpenXR Tk'   = @("$env:ProgramFiles\OpenXR-Toolkit")
}
foreach ($name in $swPaths.Keys) {
    $found = $false
    foreach ($p in $swPaths[$name]) { if (Test-Path $p) { $found = $true; break } }
    Write-Result $name ($(if ($found) {'Installed'} else {'Not found'})) ($(if ($found) {'OK'} else {'INFO'}))
}
Write-Host ''
Write-Host '  Levers inside the software (apply after hardware is sorted):' -ForegroundColor Gray
Write-Host '   - Pimax Play: lower per-eye Render Quality first; set refresh to a rate' -ForegroundColor Gray
Write-Host '     your GPU can actually sustain (90 Hz is often the sweet spot vs 120/160).' -ForegroundColor Gray
Write-Host '   - SteamVR: turn OFF auto-resolution, set a manual Render Resolution, and' -ForegroundColor Gray
Write-Host '     enable Motion Smoothing as a floor - not a crutch.' -ForegroundColor Gray
Write-Host '   - Use Quad-Views / fixed-foveated rendering (OpenXR Toolkit or native) and' -ForegroundColor Gray
Write-Host '     DLSS/DLAA where the game supports it - biggest FPS win on this headset.' -ForegroundColor Gray

# ===========================================================================
# Summary - prioritized findings
# ===========================================================================
Write-Section 'Summary - prioritized actions'
if ($findings.Count -eq 0) {
    Write-Host 'No resource restrictions detected. If framerate is still capped, the limit is' -ForegroundColor Green
    Write-Host 'inside the VR software: lower Pimax Play render quality / refresh, or the game' -ForegroundColor Green
    Write-Host 'itself is GPU-bound at your chosen supersampling.' -ForegroundColor Green
} else {
    $order = @{ 'CRITICAL'=0; 'HIGH'=1; 'MEDIUM'=2; 'LOW'=3 }
    $sorted = $findings | Sort-Object { $order[$_.Priority] }
    $i = 1
    foreach ($f in $sorted) {
        $color = switch ($f.Priority) { 'CRITICAL'{'Red'} 'HIGH'{'Red'} 'MEDIUM'{'Yellow'} default{'Gray'} }
        Write-Host ("{0}. [{1}] {2}" -f $i, $f.Priority, $f.Message) -ForegroundColor $color
        $i++
    }
    Write-Host ''
    Write-Host 'Work top-down: CRITICAL/HIGH items are what is actually restricting your' -ForegroundColor White
    Write-Host 'framerate. On the Crystal, the order of impact is almost always:' -ForegroundColor White
    Write-Host '   GPU  >  VRAM  >  RAM (dual-channel)  >  CPU  >  OS/power settings.' -ForegroundColor White
}

if ($ReportPath) {
    try { Stop-Transcript | Out-Null; Write-Host ''; Write-Host "Report saved to $ReportPath" -ForegroundColor Cyan } catch { }
}
