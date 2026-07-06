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

    A static inventory tells you what hardware you have; it cannot tell you
    which part is pegged when the Crystal drops frames. -MonitorSeconds adds
    a LIVE capture: start it, then run a demanding VR scene, and it samples
    GPU utilization, VRAM, temperature, power draw vs limit, and (on NVIDIA)
    the GPU's own clock-throttle reasons, then renders a GPU-bound vs
    CPU-bound vs power/thermal-limited verdict. That verdict is the actual
    bottleneck.

.NOTES
    Run from an *elevated* PowerShell prompt for the most complete picture
    (power plan, some driver and firmware queries):

        powershell -ExecutionPolicy Bypass -File .\Get-VRReadiness.ps1

    Save a copy of the report to a file:

        .\Get-VRReadiness.ps1 -ReportPath .\vr-report.txt

    Capture the live bottleneck: launch this, then immediately put on the
    headset and load a heavy scene for the duration of the sample window:

        .\Get-VRReadiness.ps1 -MonitorSeconds 30
#>

[CmdletBinding()]
param(
    [string]$ReportPath,
    [int]$MonitorSeconds = 0
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

function Get-Num($value) {
    # Best-effort numeric coercion that tolerates $null / strings / units.
    $n = 0.0
    if ([double]::TryParse((([string]$value).Trim()), [ref]$n)) { return $n }
    return $null
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

# ---- Locate nvidia-smi once; reused by telemetry + live capture -----------
$nvidiaSmi = $null
foreach ($cand in @(
    "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
    "$env:SystemRoot\System32\nvidia-smi.exe"
)) { if (Test-Path $cand) { $nvidiaSmi = $cand; break } }
if (-not $nvidiaSmi -and (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { $nvidiaSmi = 'nvidia-smi' }

# Decodes the clocks_throttle_reasons.active bitmask into the reasons that
# actually matter for "why is my framerate capped".
function Get-NvThrottleReasons([string]$hex) {
    if (-not $hex) { return @() }
    try { $v = [Convert]::ToInt64(($hex -replace '0x',''), 16) } catch { return @() }
    $r = @()
    if ($v -band 0x4)  { $r += 'SW power cap (hitting the power limit)' }
    if ($v -band 0x80) { $r += 'HW power brake (PSU/connector limit)' }
    if ($v -band 0x20) { $r += 'SW thermal slowdown' }
    if ($v -band 0x40) { $r += 'HW thermal slowdown (too hot)' }
    if ($v -band 0x8)  { $r += 'HW slowdown (thermal/power emergency)' }
    return $r
}

# ===========================================================================
# GPU deep telemetry (NVIDIA) - PCIe link, power headroom, current clocks
# ===========================================================================
if ($nvidiaSmi) {
    Write-Section 'GPU deep telemetry (nvidia-smi)'
    $q = @(
        'name','driver_version','vbios_version',
        'pcie.link.gen.gpucurrent','pcie.link.gen.max',
        'pcie.link.width.current','pcie.link.width.max',
        'temperature.gpu','utilization.gpu',
        'memory.used','memory.total',
        'power.draw','power.limit',
        'clocks.current.graphics','clocks.max.graphics'
    ) -join ','
    try {
        $line = & $nvidiaSmi "--query-gpu=$q" '--format=csv,noheader,nounits' 2>$null | Select-Object -First 1
        if ($line) {
            $f = $line -split '\s*,\s*'
            Write-Result 'Name'           $f[0]
            Write-Result 'Driver / VBIOS' ("{0} / {1}" -f $f[1], $f[2])

            $wCur = [int]($f[5]); $wMax = [int]($f[6])
            Write-Result 'PCIe link' ("Gen{0} x{1}  (max Gen{2} x{3})" -f $f[3],$wCur,$f[4],$wMax) `
                         ($(if ($wCur -ge $wMax) {'OK'} else {'WARN'}))
            Write-Host '  (Link gen down-trains to Gen1 at idle to save power - normal. Width is the' -ForegroundColor Gray
            Write-Host '   real signal: x16-capable cards running x8/x4 means a bad slot, riser, or' -ForegroundColor Gray
            Write-Host '   a slot sharing lanes with an M.2/USB card.)' -ForegroundColor Gray
            if ($wCur -lt $wMax) {
                Add-Finding "GPU is negotiating PCIe x$wCur but the card supports x$wMax. Reseat it in the top PCIe x16 slot (CPU lanes) and check the manual for lane-sharing with M.2/USB slots. Reduced width steals VR bandwidth." 'HIGH'
            }

            $tempNow = Get-Num $f[7]
            Write-Result 'Temp (idle/now)' ("{0} C" -f $f[7]) ($(if ($tempNow -and $tempNow -lt 75) {'OK'} else {'INFO'}))

            $vUsed = Get-Num $f[9]; $vTot = Get-Num $f[10]
            if ($vUsed -and $vTot) {
                Write-Result 'VRAM in use (now)' ("{0:N0} / {1:N0} MB" -f $vUsed, $vTot)
            }

            $pDraw = Get-Num $f[11]; $pLim = Get-Num $f[12]
            if ($pDraw -and $pLim) {
                Write-Result 'Power draw / limit' ("{0:N0} W / {1:N0} W" -f $pDraw, $pLim)
            }
            Write-Result 'Graphics clock now/max' ("{0} / {1} MHz" -f $f[13], $f[14])
        }
    } catch { Write-Result 'nvidia-smi query' "Error: $_" 'WARN' }

    # Human-readable throttle status (idle snapshot; the live capture below
    # is what really matters, but flag a card that is already throttling).
    try {
        $tline = & $nvidiaSmi '--query-gpu=clocks_throttle_reasons.active' '--format=csv,noheader' 2>$null | Select-Object -First 1
        $reasons = Get-NvThrottleReasons $tline
        if ($reasons) {
            Write-Result 'Active throttle (idle)' ($reasons -join '; ') 'WARN'
        } else {
            Write-Result 'Active throttle (idle)' 'none' 'OK'
        }
    } catch { }
} else {
    Write-Section 'GPU deep telemetry'
    Write-Result 'nvidia-smi' 'Not found (non-NVIDIA GPU, or NVSMI missing)' 'INFO'
    Write-Host '  AMD GPUs have no equivalent CLI by default. For PCIe link width, power,' -ForegroundColor Gray
    Write-Host '  and throttle status use GPU-Z and watch the sensors tab during a session.' -ForegroundColor Gray
}

# ---- Resizable BAR (real VR uplift on modern cards) -----------------------
Write-Host ''
Write-Result 'Resizable BAR' 'Verify manually' 'INFO'
Write-Host '  ReBAR is not reliably readable from script. Confirm it in GPU-Z (says' -ForegroundColor Gray
Write-Host '  "Resizable BAR: Enabled") or the NVIDIA Control Panel system info. If it is' -ForegroundColor Gray
Write-Host '  off, enable "Above 4G Decoding" + "Re-Size BAR Support" in BIOS - it lifts' -ForegroundColor Gray
Write-Host '  framerate in several VR titles for free.' -ForegroundColor Gray

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

# Pagefile: a system-managed pagefile on a fast drive prevents hard stalls
# when VRAM/RAM pressure spikes mid-session.
try {
    $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction Stop
    if ($pf) {
        foreach ($p in $pf) {
            Write-Result 'Pagefile' ("{0}  ({1} MB allocated, {2} MB peak)" -f $p.Name, $p.AllocatedBaseSize, $p.PeakUsage)
        }
    } else {
        Write-Result 'Pagefile' 'None configured' 'WARN'
        Add-Finding 'No pagefile is configured. With a fixed/absent pagefile, a VRAM or RAM spike can hard-crash the game instead of paging. Leave it System managed (on a fast SSD).' 'MEDIUM'
    }
} catch { Write-Result 'Pagefile' "Could not query" 'INFO' }

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

    # Current mode per display (resolution + refresh). The Crystal shows up
    # here as a display while active - a low refresh value is a red flag.
    try {
        $vid = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution }
        foreach ($v in $vid) {
            Write-Result ('  ' + $v.Name) ("{0}x{1} @ {2} Hz" -f $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution, $v.CurrentRefreshRate)
        }
    } catch { }
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

# Looks past default install paths: also checks the uninstall registry and,
# for SteamVR, every Steam library (games are often on another drive).
function Test-AppInstalled([string]$pattern, [string[]]$paths) {
    foreach ($p in $paths) { if ($p -and (Test-Path $p)) { return $true } }
    foreach ($k in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        if (Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $pattern }) { return $true }
    }
    return $false
}

# Resolve the Steam install + all library folders to find SteamVR anywhere.
$steamVrFound = $false
try {
    $steamPath = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
    if ($steamPath) {
        $libs = @($steamPath)
        $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            (Get-Content $vdf) | Select-String '"path"\s*"(.+?)"' | ForEach-Object {
                $libs += ($_.Matches.Groups[1].Value -replace '\\\\','\')
            }
        }
        foreach ($l in $libs) {
            if (Test-Path (Join-Path $l 'steamapps\common\SteamVR')) { $steamVrFound = $true; break }
        }
    }
} catch { }

$pimax  = Test-AppInstalled 'Pimax' @("$env:ProgramFiles\Pimax", "${env:ProgramFiles(x86)}\Pimax", "$env:LOCALAPPDATA\Pimax", "$env:ProgramData\Pimax")
$openxr = Test-AppInstalled 'OpenXR.?Toolkit' @("$env:ProgramFiles\OpenXR-Toolkit")
Write-Result 'Pimax Play' ($(if ($pimax)       {'Installed'} else {'Not found'})) ($(if ($pimax)       {'OK'} else {'INFO'}))
Write-Result 'SteamVR'    ($(if ($steamVrFound){'Installed'} else {'Not found'})) ($(if ($steamVrFound){'OK'} else {'INFO'}))
Write-Result 'OpenXR Tk'  ($(if ($openxr)      {'Installed'} else {'Not found'})) ($(if ($openxr)      {'OK'} else {'INFO'}))
Write-Host ''
Write-Host '  Levers inside the software (apply after hardware is sorted):' -ForegroundColor Gray
Write-Host '   - Pimax Play: lower per-eye Render Quality first; set refresh to a rate' -ForegroundColor Gray
Write-Host '     your GPU can actually sustain (90 Hz is often the sweet spot vs 120/160).' -ForegroundColor Gray
Write-Host '   - SteamVR: turn OFF auto-resolution, set a manual Render Resolution, and' -ForegroundColor Gray
Write-Host '     enable Motion Smoothing as a floor - not a crutch.' -ForegroundColor Gray
Write-Host '   - Use Quad-Views / fixed-foveated rendering (OpenXR Toolkit or native) and' -ForegroundColor Gray
Write-Host '     DLSS/DLAA where the game supports it - biggest FPS win on this headset.' -ForegroundColor Gray

# ===========================================================================
# Driver health - devices with problems and key driver versions/dates
# ===========================================================================
Write-Section 'Driver health'
try {
    # Devices Windows flags as broken / unconfigured = stalls, dropped USB,
    # fallback drivers. These quietly cost performance and stability.
    $bad = Get-PnpDevice -PresentOnly -ErrorAction Stop |
           Where-Object { $_.Status -ne 'OK' -and $_.Class -notin @('SoftwareDevice') }
    if ($bad) {
        foreach ($d in $bad) {
            Write-Result ('  ' + $d.Class) ("{0}  [{1}]" -f $d.FriendlyName, $d.Status) 'WARN'
        }
        Add-Finding ("$($bad.Count) device(s) report a non-OK driver status (Device Manager would show a yellow !). Open devmgmt.msc, find the flagged devices, and Update/reinstall drivers - especially anything under Display, USB, or System devices, which sit directly in the VR path.") 'MEDIUM'
    } else {
        Write-Result 'Devices with driver problems' 'none' 'OK'
    }
} catch { Write-Result 'PnP device status' "Could not query ($_)" 'INFO' }

# Key driver versions/dates for the components that touch the VR pipeline.
try {
    $classes = 'DISPLAY','USB','Net','System','HDC','SCSIAdapter'
    $drv = Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
           Where-Object { $_.DeviceClass -in $classes -and $_.DriverDate }
    Write-Host ''
    Write-Host '  Component drivers (provider / version / date):' -ForegroundColor Gray
    foreach ($cls in $classes) {
        $rows = $drv | Where-Object { $_.DeviceClass -eq $cls } |
                Sort-Object DeviceName -Unique | Select-Object -First 4
        foreach ($d in $rows) {
            $dd = $null
            if ($d.DriverDate -is [datetime]) { $dd = $d.DriverDate }
            else { try { $dd = [Management.ManagementDateTimeConverter]::ToDateTime([string]$d.DriverDate) } catch { } }
            $stamp = if ($dd) { $dd.ToString('yyyy-MM-dd') } else { 'unknown' }
            Write-Result ('  [' + $cls + '] ' + $d.DeviceName) ("{0}  v{1}  {2}" -f $d.DriverProviderName, $d.DriverVersion, $stamp)
            # Flag chipset/USB/storage/network drivers older than ~3 years -
            # these are a common silent cause of USB dropouts and DPC latency.
            if ($dd -and $cls -in @('USB','System','HDC','Net') -and ((Get-Date) - $dd).TotalDays -gt 1095 `
                -and $d.DriverProviderName -notmatch 'Microsoft') {
                Add-Finding ("Driver for '$($d.DeviceName)' ($cls) is from $stamp - over 3 years old. Chipset/USB/storage/LAN drivers this old cause USB disconnects and DPC-latency stutter in VR. Install the current chipset + LAN drivers from your motherboard vendor.") 'MEDIUM'
            }
        }
    }
    Write-Host '  Tip: install the motherboard vendors full CHIPSET package (not just' -ForegroundColor Gray
    Write-Host '  Windows Update versions) - it carries the USB/PCIe/power drivers VR leans on.' -ForegroundColor Gray
} catch { Write-Result 'Driver inventory' "Could not query ($_)" 'INFO' }

# ===========================================================================
# Startup & auto-start load - what eats capacity before you launch anything
# ===========================================================================
Write-Section 'Startup & background load'
try {
    $startup = Get-CimInstance Win32_StartupCommand -ErrorAction Stop
    Write-Result 'Startup entries' ($startup.Count) ($(if ($startup.Count -gt 12) {'WARN'} else {'INFO'}))
    $startup | Select-Object -First 15 | ForEach-Object {
        Write-Result ('  ' + $_.Name) ($_.Location)
    }
    if ($startup.Count -gt 12) {
        Add-Finding "$($startup.Count) startup entries are configured. Each one holds RAM/CPU and some keep a GPU overlay alive. Trim non-essentials in Task Manager > Startup (keep GPU driver + audio; disable RGB suites, updaters, launchers you open manually)." 'LOW'
    }
} catch { Write-Result 'Startup commands' "Could not query ($_)" 'INFO' }

# Known vendor/RGB/telemetry services that run constantly and add overhead.
try {
    $noisy = Get-CimInstance Win32_Service -ErrorAction Stop |
             Where-Object { $_.State -eq 'Running' -and $_.StartMode -eq 'Auto' -and
                 $_.Name -match 'Razer|Corsair|iCUE|Armoury|AsusComService|LightingService|ROG|MSI_|NahimicService|Killer|GamingServices|RtkAudioService|LogiRegistryService|NvTelemetry|NvContainerLocalSystem' }
    if ($noisy) {
        Write-Host ''
        Write-Result 'Always-on vendor services' (($noisy | Select-Object -Expand DisplayName -Unique) -join '; ') 'WARN'
        Add-Finding 'RGB / vendor / telemetry services are running continuously (Razer/Corsair/Armoury/Nahimic/NVIDIA telemetry, etc.). They add CPU wakeups and DPC latency that show up as VR microstutter. Disable the ones you do not actively use via services.msc or their tray apps.' 'LOW'
    }
} catch { }

# ===========================================================================
# Live load capture - the actual bottleneck verdict (opt-in)
# ===========================================================================
if ($MonitorSeconds -gt 0) {
    Write-Section ("Live load capture - sampling for {0}s" -f $MonitorSeconds)
    Write-Host '>>> PUT THE HEADSET ON AND LOAD A DEMANDING VR SCENE NOW <<<' -ForegroundColor Yellow
    Write-Host 'Sampling ~once per second. Keep the heavy scene on screen the whole time.' -ForegroundColor Gray
    Write-Host ''

    $gpuUtil=@(); $vramPct=@(); $temps=@(); $powerPct=@(); $cpuUtil=@(); $throttles=@{}
    $end = (Get-Date).AddSeconds($MonitorSeconds)
    while ((Get-Date) -lt $end) {
        if ($nvidiaSmi) {
            $s = & $nvidiaSmi '--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,clocks_throttle_reasons.active' '--format=csv,noheader,nounits' 2>$null | Select-Object -First 1
            if ($s) {
                $c = $s -split '\s*,\s*'
                $u = Get-Num $c[0];  if ($null -ne $u) { $gpuUtil += $u }
                $mu = Get-Num $c[1]; $mt = Get-Num $c[2]; if ($mu -and $mt) { $vramPct += ($mu / $mt * 100) }
                $t = Get-Num $c[3];  if ($null -ne $t) { $temps += $t }
                $pd = Get-Num $c[4]; $pl = Get-Num $c[5]; if ($pd -and $pl) { $powerPct += ($pd / $pl * 100) }
                foreach ($r in (Get-NvThrottleReasons $c[6])) { $throttles[$r] = $true }
            }
        } else {
            # AMD / fallback: GPU 3D-engine utilization via perf counters.
            try {
                $g = (Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop).CounterSamples |
                     Measure-Object -Property CookedValue -Maximum
                if ($g) { $gpuUtil += [math]::Min(100, [double]$g.Maximum) }
            } catch { }
        }
        $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        if ($null -ne $cpu) { $cpuUtil += [double]$cpu }
        Start-Sleep -Milliseconds 900
    }

    if ($gpuUtil.Count -eq 0) {
        Write-Result 'Live capture' 'No GPU samples collected (no nvidia-smi and GPU counters unavailable)' 'WARN'
    } else {
        $avgG = [math]::Round(($gpuUtil | Measure-Object -Average).Average, 0)
        $maxG = [math]::Round(($gpuUtil | Measure-Object -Maximum).Maximum, 0)
        $avgC = if ($cpuUtil.Count) { [math]::Round(($cpuUtil | Measure-Object -Average).Average, 0) } else { $null }
        $maxT = if ($temps.Count)   { [math]::Round(($temps   | Measure-Object -Maximum).Maximum, 0) } else { $null }
        $maxP = if ($powerPct.Count){ [math]::Round(($powerPct| Measure-Object -Maximum).Maximum, 0) } else { $null }
        $maxV = if ($vramPct.Count) { [math]::Round(($vramPct | Measure-Object -Maximum).Maximum, 0) } else { $null }

        Write-Result 'Samples'                 ($gpuUtil.Count)
        Write-Result 'GPU utilization avg/max' ("{0}% / {1}%" -f $avgG, $maxG)
        if ($null -ne $avgC) { Write-Result 'CPU utilization avg'  ("{0}%" -f $avgC) ($(if ($avgC -ge 85) {'WARN'} else {'INFO'})) }
        if ($null -ne $maxV) { Write-Result 'VRAM peak'            ("{0}%" -f $maxV) ($(if ($maxV -ge 92) {'WARN'} else {'OK'})) }
        if ($null -ne $maxT) { Write-Result 'GPU temp peak'        ("{0} C" -f $maxT) ($(if ($maxT -ge 84) {'WARN'} else {'OK'})) }
        if ($null -ne $maxP) { Write-Result 'Power peak (% limit)' ("{0}%" -f $maxP) }
        if ($throttles.Keys.Count) { Write-Result 'Throttle reasons seen' (($throttles.Keys) -join '; ') 'WARN' }

        # ---- Bottleneck verdict ----
        Write-Host ''
        if ($avgG -ge 95) {
            Write-Host 'VERDICT: GPU-BOUND. The GPU is saturated - it is the framerate ceiling.' -ForegroundColor Red
            Add-Finding 'LIVE: GPU was saturated (avg >=95%) - you are GPU-bound, the expected high-FPS limiter on the Crystal. To raise framerate without new hardware: lower per-eye render quality in Pimax Play, drop to 90 Hz, enable DLSS/DLAA, and turn on Quad-Views / fixed-foveated rendering. Keeping BOTH full resolution and high framerate needs a faster GPU.' 'HIGH'
        } elseif ($avgG -lt 85 -and $null -ne $avgC -and $avgC -ge 70) {
            Write-Host 'VERDICT: CPU-BOUND. GPU has headroom but the CPU is the limiter.' -ForegroundColor Red
            Add-Finding "LIVE: GPU averaged only $avgG% while CPU averaged $avgC% - you are CPU-bound. Raising GPU/visual settings is nearly free here. Fix the CPU side: close background load, confirm High Performance power plan, and check for a single-thread limit (sim-heavy titles). More GPU will NOT help until the CPU side is addressed." 'HIGH'
        } elseif ($avgG -lt 85) {
            Write-Host 'VERDICT: GPU NOT SATURATED. Something caps frames before the GPU.' -ForegroundColor Yellow
            Add-Finding "LIVE: GPU averaged only $avgG% and was not the limiter. Likely a refresh/reprojection cap (SteamVR Motion Smoothing locking to half-rate), a CPU/single-thread limit, or too-low in-app render resolution. Open the SteamVR frame-timing graph and compare the CPU vs GPU lines to confirm." 'HIGH'
        } else {
            Write-Host ('VERDICT: GPU heavily loaded (avg {0}%) - near the ceiling.' -f $avgG) -ForegroundColor Yellow
        }

        if (($throttles.Keys -join ' ') -match 'power') {
            Add-Finding 'LIVE: the GPU hit its POWER limit during the scene. Raise the power limit (MSI Afterburner), give it two separate PCIe power cables instead of one daisy-chained cable, verify the PSU has headroom, or undervolt to hold higher clocks within budget.' 'HIGH'
        }
        if ((($throttles.Keys -join ' ') -match 'thermal') -or ($null -ne $maxT -and $maxT -ge 84)) {
            Add-Finding ("LIVE: the GPU was thermally limited (peak {0} C). Improve case airflow, raise the fan curve, repaste if the card is old, or undervolt. Thermal throttling silently caps clocks and framerate." -f $maxT) 'HIGH'
        }
        if ($null -ne $maxV -and $maxV -ge 92) {
            Add-Finding "LIVE: VRAM peaked at $maxV% of capacity - you are near a VRAM wall. Lower texture resolution / supersampling in-game, or this is the concrete case for a higher-VRAM GPU." 'HIGH'
        }
    }
}

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

if ($MonitorSeconds -le 0) {
    Write-Host ''
    Write-Host 'This was a static scan. To capture the REAL bottleneck under load, re-run' -ForegroundColor Cyan
    Write-Host 'during a VR session:  .\Get-VRReadiness.ps1 -MonitorSeconds 30' -ForegroundColor Cyan
    Write-Host 'It will tell you whether you are GPU-bound, CPU-bound, or power/thermal-limited.' -ForegroundColor Cyan
}

if ($ReportPath) {
    try { Stop-Transcript | Out-Null; Write-Host ''; Write-Host "Report saved to $ReportPath" -ForegroundColor Cyan } catch { }
}
