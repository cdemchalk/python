#Requires -Version 5.1
<#
Inventories the hardware and Windows settings that matter for VR frame rate
(Pimax + RTX 4090, targeting MS Flight Simulator and Assetto Corsa) and
flags anything that is costing FPS.

Run from an *elevated* PowerShell prompt:
    powershell -ExecutionPolicy Bypass -File .\Check-VrPerformance.ps1

Pair the output with VR-FPS-OPTIMIZATION.md in this folder, which explains
the per-game and per-headset settings this script cannot see.
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
    '{0,-36} {1}' -f ($Label + ':'), $Value | Write-Host -ForegroundColor $color
}

$findings = [System.Collections.Generic.List[string]]::new()
function Add-Finding([string]$msg) { $findings.Add($msg) }

$isAdmin = ([Security.Principal.WindowsPrincipal] `
           [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'WARNING: not elevated. Some checks (power plan, services) will be incomplete.' -ForegroundColor Yellow
}

# ---- CPU -------------------------------------------------------------------
Write-Section 'CPU (the usual MSFS VR bottleneck, not the 4090)'

try {
    $cpu = Get-CimInstance Win32_Processor
    Write-Result 'Model'            $cpu.Name.Trim()
    Write-Result 'Cores / threads'  "$($cpu.NumberOfCores) / $($cpu.NumberOfLogicalProcessors)"
    Write-Result 'Max clock'        "$($cpu.MaxClockSpeed) MHz"

    # MSFS is dominated by single-thread performance. Flag CPU generations
    # that will hold a 4090 back in VR regardless of settings.
    $name = $cpu.Name
    $weakCpu = $false
    if ($name -match 'i[3579]-(\d{4,5})') {
        # 4-digit model = gen 2-9 (first digit); 5-digit = gen 10+ (first two)
        $model = $Matches[1]
        $gen = if ($model.Length -eq 5) { [int]$model.Substring(0, 2) } else { [int]$model.Substring(0, 1) }
        $weakCpu = $gen -le 10
    } elseif ($name -match 'Ryzen [3579] (\d)\d{3}') {
        $weakCpu = [int]$Matches[1] -le 3   # Ryzen 3000 or older
    }
    $isX3D = $name -match 'X3D'
    if ($weakCpu) {
        Write-Result 'VR suitability' 'Likely main-thread bottleneck for MSFS' 'FAIL'
        Add-Finding "CPU ($($name.Trim())) is old enough to be the primary MSFS VR bottleneck with a 4090. In MSFS dev-mode FPS counter you will see 'Limited by MainThread'. The single best hardware upgrade is a Ryzen 7 9800X3D / 7800X3D (the 3D V-Cache is disproportionately good for MSFS and rFactor-style sims)."
    } elseif ($isX3D) {
        Write-Result 'VR suitability' 'X3D cache CPU - ideal for sims' 'OK'
    } else {
        Write-Result 'VR suitability' 'Modern CPU; verify with MSFS dev-mode counter' 'OK'
    }
} catch {
    Write-Result 'Win32_Processor' "Error: $_" 'WARN'
}

# ---- RAM -------------------------------------------------------------------
Write-Section 'Memory'

try {
    $dimms = @(Get-CimInstance Win32_PhysicalMemory)
    $totalGB = [math]::Round(($dimms | Measure-Object Capacity -Sum).Sum / 1GB, 0)
    $speeds  = ($dimms | Select-Object -ExpandProperty ConfiguredClockSpeed -Unique) -join ', '
    $rated   = ($dimms | Select-Object -ExpandProperty Speed -Unique) -join ', '
    Write-Result 'Total'                 "$totalGB GB in $($dimms.Count) DIMM(s)"
    Write-Result 'Configured speed'      "$speeds MT/s"
    Write-Result 'Rated (SPD/XMP) speed' "$rated MT/s"

    if ($totalGB -lt 32) {
        Write-Result 'Capacity check' 'Below 32 GB' 'FAIL'
        Add-Finding "Only $totalGB GB RAM. MSFS in VR with photogrammetry regularly commits >24 GB; when it spills to the page file you get stutter that no graphics setting fixes. Upgrade to 32 GB minimum, 64 GB is the comfortable target."
    } elseif ($totalGB -lt 64) {
        Write-Result 'Capacity check' '32 GB - adequate for MSFS VR' 'OK'
    } else {
        Write-Result 'Capacity check' "$totalGB GB - plenty" 'OK'
    }

    if ($dimms.Count -eq 1) {
        Add-Finding 'Only one DIMM populated = single-channel memory. That roughly halves memory bandwidth and directly costs CPU frame time in MSFS. Add a second matched stick.'
        Write-Result 'Channel check' 'SINGLE CHANNEL' 'FAIL'
    } elseif ($dimms.Count % 2 -eq 1) {
        Write-Result 'Channel check' "Odd DIMM count ($($dimms.Count)) - verify channel config" 'WARN'
    } else {
        Write-Result 'Channel check' 'Dual (or better) channel' 'OK'
    }

    $cfg = $dimms | Select-Object -First 1
    if ($cfg.ConfiguredClockSpeed -and $cfg.Speed -and
        $cfg.ConfiguredClockSpeed -lt $cfg.Speed) {
        Write-Result 'XMP/EXPO check' "Running $($cfg.ConfiguredClockSpeed), rated $($cfg.Speed)" 'WARN'
        Add-Finding "RAM is running at $($cfg.ConfiguredClockSpeed) MT/s but the sticks are rated for $($cfg.Speed) MT/s. XMP/EXPO is probably disabled in BIOS. Enabling it is a free 5-15% CPU-bound FPS gain in MSFS."
    }
} catch {
    Write-Result 'Win32_PhysicalMemory' "Error: $_" 'WARN'
}

# ---- GPU -------------------------------------------------------------------
Write-Section 'GPU'

try {
    $gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Status -eq 'OK' })
    foreach ($g in $gpus) {
        Write-Result 'Adapter'        $g.Name
        Write-Result 'Driver version' $g.DriverVersion
        Write-Result 'Driver date'    ($g.DriverDate)
    }
    $nv = $gpus | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
    if ($nv -and $nv.DriverDate -and ((Get-Date) - $nv.DriverDate).TotalDays -gt 180) {
        Add-Finding "NVIDIA driver is older than 6 months ($($nv.DriverDate.ToShortDateString())). Update via the NVIDIA app - VR-specific fixes land regularly, and Pimax firmware often assumes a recent driver."
    }
    if ($gpus.Count -gt 1 -and ($gpus | Where-Object { $_.Name -match 'Intel|AMD Radeon\(TM\) Graphics' })) {
        Write-Result 'iGPU present' 'Yes - make sure the headset DisplayPort is on the 4090' 'WARN'
    }
} catch {
    Write-Result 'Win32_VideoController' "Error: $_" 'WARN'
}

# nvidia-smi gives PCIe link + Resizable BAR, which WMI cannot see
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $smi) {
    $default = "$env:SystemRoot\System32\nvidia-smi.exe"
    if (Test-Path $default) { $smi = @{ Source = $default } }
}
if ($smi) {
    try {
        $q = & $smi.Source --query-gpu=name,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,memory.total --format=csv,noheader 2>$null
        if ($LASTEXITCODE -eq 0 -and $q) {
            $f = ($q | Select-Object -First 1) -split ',\s*'
            Write-Result 'PCIe link (current/max gen)' "$($f[1]) / $($f[2])"
            Write-Result 'PCIe width'                  $f[3]
            Write-Result 'VRAM'                        $f[4]
            if ([int]$f[3].Trim() -lt 16) {
                Add-Finding "4090 is running at PCIe x$($f[3].Trim()) instead of x16. Check the card is in the top slot and that an M.2 drive is not stealing lanes (common on consumer boards - see the motherboard manual's lane-sharing table)."
            }
            if ([int]$f[1] -lt [int]$f[2]) {
                Write-Result 'PCIe gen check' "Running gen $($f[1]) of gen $($f[2]) capable" 'WARN'
            }
        }
    } catch { Write-Result 'nvidia-smi' "Error: $_" 'WARN' }

    try {
        $rebar = & $smi.Source -q 2>$null | Select-String 'ReBAR|Resizable'
        if ($rebar) { $rebar | ForEach-Object { Write-Host "  $($_.Line.Trim())" -ForegroundColor Gray } }
    } catch { }
} else {
    Write-Result 'nvidia-smi' 'Not found - skipping PCIe/ReBAR checks' 'WARN'
}

# ---- Windows graphics settings ---------------------------------------------
Write-Section 'Windows graphics settings'

try {
    $hags = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction Stop).HwSchMode
    switch ($hags) {
        2 { Write-Result 'HW-accelerated GPU scheduling' 'Enabled' 'OK' }
        1 { Write-Result 'HW-accelerated GPU scheduling' 'Disabled' 'WARN'
            Add-Finding 'Hardware-accelerated GPU scheduling (HAGS) is off. Required for DLSS Frame Generation in MSFS 2024 and generally helps VR frame pacing on a 4090. Settings > System > Display > Graphics > Change default graphics settings.' }
        default { Write-Result 'HW-accelerated GPU scheduling' 'OS default / unknown' }
    }
} catch { Write-Result 'HAGS' 'Not readable' 'WARN' }

try {
    $gameDvr = (Get-ItemProperty 'HKCU:\System\GameConfigStore' -ErrorAction Stop).GameDVR_Enabled
    if ($gameDvr -eq 1) {
        Write-Result 'Game DVR / background recording' 'Enabled' 'WARN'
        Add-Finding 'Xbox Game DVR background recording is on. It costs frame time and adds stutter in VR. Settings > Gaming > Captures > turn off "Record what happened".'
    } else {
        Write-Result 'Game DVR / background recording' 'Disabled' 'OK'
    }
} catch { Write-Result 'Game DVR' 'Not readable' }

# Memory Integrity (HVCI) costs measurable CPU time in CPU-bound games.
try {
    $hvci = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -ErrorAction Stop).Enabled
    if ($hvci -eq 1) {
        Write-Result 'Memory Integrity (HVCI)' 'Enabled' 'WARN'
        Add-Finding 'Memory Integrity (Core Isolation) is on. It typically costs ~5% CPU performance, which matters in main-thread-bound MSFS. Turning it off is a security trade-off - your call. Windows Security > Device security > Core isolation.'
    } else {
        Write-Result 'Memory Integrity (HVCI)' 'Disabled' 'OK'
    }
} catch { Write-Result 'Memory Integrity (HVCI)' 'Not configured' 'OK' }

try {
    $plan = powercfg /getactivescheme 2>$null
    Write-Result 'Active power plan' (($plan -replace '^.*\((.*)\).*$', '$1'))
    if ($plan -match 'Power saver|Balanced') {
        Add-Finding 'Power plan is not High performance / Ultimate. On desktops set High performance (or the chipset vendor plan) so the CPU does not downclock between frames - VR is very sensitive to clock ramp latency.'
    }
} catch { Write-Result 'Power plan' 'Not readable' 'WARN' }

# ---- Storage (MSFS streams constantly) --------------------------------------
Write-Section 'Storage'

try {
    Get-PhysicalDisk | ForEach-Object {
        $status = if ($_.MediaType -eq 'HDD') { 'WARN' } else { 'OK' }
        Write-Result "$($_.FriendlyName)" "$($_.MediaType), Bus=$($_.BusType), $([math]::Round($_.Size/1GB)) GB" $status
    }
    if (Get-PhysicalDisk | Where-Object MediaType -eq 'HDD') {
        Add-Finding 'A spinning HDD is present. If MSFS, its rolling cache, or Assetto Corsa content is installed on it, move them to NVMe - MSFS streams scenery continuously and an HDD causes texture pop and pauses.'
    }
} catch { Write-Result 'Get-PhysicalDisk' "Error: $_" 'WARN' }

# ---- Page file --------------------------------------------------------------
try {
    $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction Stop
    if ($pf) {
        $pf | ForEach-Object { Write-Result "Page file $($_.Name)" "$($_.AllocatedBaseSize) MB allocated" }
    } else {
        Write-Result 'Page file' 'None configured' 'WARN'
        Add-Finding 'No page file configured. MSFS commits far more than it uses and will crash to desktop without one, even with lots of RAM. Set system-managed on the fastest SSD.'
    }
} catch { }

# ---- VR software stack -------------------------------------------------------
Write-Section 'VR software stack'

# Active OpenXR runtime - decides whether MSFS renders through Pimax's
# runtime, SteamVR, or something else entirely.
try {
    $xr = (Get-ItemProperty 'HKLM:\SOFTWARE\Khronos\OpenXR\1' -ErrorAction Stop).ActiveRuntime
    Write-Result 'Active OpenXR runtime' $xr
    if ($xr -match 'SteamVR') {
        Add-Finding 'Active OpenXR runtime is SteamVR. For MSFS on a Pimax, PimaxXR (or the runtime built into Pimax Play) is significantly faster than going through SteamVR - it skips a whole compositor. Switch in Pimax Play or the PimaxXR control panel.'
    } elseif ($xr -match 'Pimax') {
        Write-Result 'Runtime check' 'Pimax native runtime - correct for MSFS' 'OK'
    }
} catch {
    Write-Result 'Active OpenXR runtime' 'Not registered' 'WARN'
    Add-Finding 'No OpenXR runtime registered. MSFS requires OpenXR - install/repair Pimax Play and set it as the OpenXR runtime.'
}

foreach ($app in @(
    @{ Name = 'Pimax Play';     Paths = @("$env:ProgramFiles\Pimax\PimaxClient", "${env:ProgramFiles(x86)}\Pimax") },
    @{ Name = 'PimaxXR';        Paths = @("$env:ProgramFiles\PimaxXR") },
    @{ Name = 'SteamVR';        Paths = @("${env:ProgramFiles(x86)}\Steam\steamapps\common\SteamVR") },
    @{ Name = 'OpenXR Toolkit'; Paths = @("$env:ProgramFiles\OpenXR-Toolkit") },
    @{ Name = 'fpsVR';          Paths = @("${env:ProgramFiles(x86)}\Steam\steamapps\common\fpsVR") }
)) {
    $found = $app.Paths | Where-Object { Test-Path $_ } | Select-Object -First 1
    Write-Result $app.Name ($(if ($found) { "Installed ($found)" } else { 'Not found' }))
}

# ---- Known FPS-eating background processes -----------------------------------
Write-Section 'Background processes worth checking'

$suspects = @{
    'iCUE'            = 'Corsair iCUE - RGB polling causes stutter spikes; close while flying'
    'LightingService' = 'ASUS Aura - same issue'
    'RGBFusion'       = 'Gigabyte RGB Fusion - same issue'
    'MSIAfterburner'  = 'Fine, but disable its overlay (RTSS) inside VR'
    'RTSS'            = 'RivaTuner overlay can conflict with VR compositors'
    'Wallpaper64'     = 'Wallpaper Engine - pause it during VR'
    'Discord'         = 'Disable hardware acceleration and the in-game overlay'
    'GameBar'         = 'Xbox Game Bar overlay'
    'OneDrive'        = 'Pause syncing during sessions'
}
$foundAny = $false
foreach ($p in $suspects.GetEnumerator()) {
    if (Get-Process -Name $p.Key -ErrorAction SilentlyContinue) {
        Write-Result $p.Key $p.Value 'WARN'
        $foundAny = $true
    }
}
if (-not $foundAny) { Write-Result 'Scan' 'None of the usual suspects running' 'OK' }

# ---- Summary -----------------------------------------------------------------
Write-Section 'Summary'
if ($findings.Count -eq 0) {
    Write-Host 'No hardware/OS issues detected. Remaining FPS gains are in per-game and Pimax settings - see VR-FPS-OPTIMIZATION.md.' -ForegroundColor Green
} else {
    for ($i = 0; $i -lt $findings.Count; $i++) {
        Write-Host ("{0}. {1}" -f ($i + 1), $findings[$i]) -ForegroundColor Yellow
        Write-Host ''
    }
    Write-Host 'Next: work through VR-FPS-OPTIMIZATION.md for the Pimax, MSFS and Assetto Corsa settings this script cannot inspect.' -ForegroundColor Gray
}
