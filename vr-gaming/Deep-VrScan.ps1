#Requires -Version 5.1
<#
Deeper VR performance scan, meant to be run and interpreted by a local
Claude Code session (or by hand). Goes past Check-VrPerformance.ps1 into the
areas that usually need live probing on an i9-12900K + RTX 4090 + Pimax
Crystal: live GPU telemetry + throttle reasons, hybrid P/E-core scheduling,
display-driver timeout (TDR) history, per-app GPU preference, the MSFS
config it can find, startup/background load, USB port of the headset, and
latency-relevant Windows settings.

Run from an *elevated* PowerShell prompt:
    powershell -ExecutionPolicy Bypass -File .\Deep-VrScan.ps1

Nothing here changes settings; it only reads state.
#>

[CmdletBinding()]
param([int]$GpuSamples = 5)

$ErrorActionPreference = 'Continue'

function Write-Section($title) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    Write-Host $title -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkGray
}
function Write-Result {
    param([string]$Label,[string]$Value,
          [ValidateSet('OK','WARN','FAIL','INFO')][string]$Status='INFO')
    $c = switch ($Status) { 'OK'{'Green'} 'WARN'{'Yellow'} 'FAIL'{'Red'} default{'Gray'} }
    '{0,-40} {1}' -f ($Label + ':'), $Value | Write-Host -ForegroundColor $c
}
$findings = [System.Collections.Generic.List[string]]::new()
function Add-Finding([string]$m) { $findings.Add($m) }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'WARNING: not elevated - event log, some counters incomplete.' -ForegroundColor Yellow }

# ---- Live GPU telemetry + throttle reasons ---------------------------------
Write-Section "Live GPU telemetry ($GpuSamples samples)"
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $smi) { $d="$env:SystemRoot\System32\nvidia-smi.exe"; if (Test-Path $d){$smi=@{Source=$d}} }
if ($smi) {
    for ($i=0; $i -lt [Math]::Max(1,$GpuSamples); $i++) {
        $r = & $smi.Source --query-gpu=temperature.gpu,utilization.gpu,clocks.sm,clocks.max.sm,power.draw,power.limit --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0) {
            $f = $r -split ',\s*'
            Write-Result "sample $($i+1)" "temp=$($f[0])C util=$($f[1])% sm=$($f[2])/$($f[3])MHz pwr=$($f[4])/$($f[5])W"
        }
        Start-Sleep -Milliseconds 400
    }
    # Throttle reasons are the real signal - active clocks-throttle under load = bad
    $thr = & $smi.Source -q -d PERFORMANCE 2>$null | Select-String 'Throttle|Idle|SW Power|HW|Thermal|Reliability|Boost'
    if ($thr) {
        Write-Host '  --- clocks throttle reasons ---' -ForegroundColor Gray
        $thr | ForEach-Object { Write-Host "    $($_.Line.Trim())" -ForegroundColor Gray }
        if (($thr | Select-String 'Thermal.*Active|SW Thermal.*Active|HW Thermal.*Active')) {
            Add-Finding 'GPU reports an ACTIVE thermal throttle. A 4090 throttling mid-flight looks exactly like a settings problem. Check case airflow and GPU temps under load (target hotspot < 90C); repaste/undervolt if sustained.'
        }
        if (($thr | Select-String 'SW Power Cap.*Active')) {
            Add-Finding 'GPU is hitting its power cap. Normal at full load, but if you want headroom, raise the power limit in MSI Afterburner (up to 133% on a 4090) or apply an undervolt/OC curve for higher sustained clocks at the same power.'
        }
    }
    # Re-run this section WHILE MSFS/AC is running for the meaningful reading.
    Write-Host '  (Re-run this while a game is running for load numbers that matter.)' -ForegroundColor DarkGray
} else { Write-Result 'nvidia-smi' 'Not found' 'WARN' }

# ---- Hybrid CPU (P/E cores) + scheduling -----------------------------------
Write-Section 'CPU topology + scheduling (12th-gen hybrid)'
try {
    $cpu = Get-CimInstance Win32_Processor
    $cores = $cpu.NumberOfCores; $threads = $cpu.NumberOfLogicalProcessors
    Write-Result 'Cores / threads' "$cores / $threads"
    if ($threads -lt (2*$cores)) {
        $pCores = $threads - $cores      # each P-core adds a 2nd thread; E-cores don't
        $eCores = $cores - $pCores
        Write-Result 'Topology' "$pCores P-cores (HT) + $eCores E-cores" 'INFO'
        Add-Finding "Hybrid CPU detected ($pCores P + $eCores E cores). MSFS's main thread must run on a P-core; if Windows parks it on an E-core you lose a lot of FPS. If MSFS dev-mode shows MainThread-limited, test pinning the sim to P-cores only (Process Lasso, or set affinity in Task Manager) and confirm 'Hardware default scheduling' / Thread Director is working (BIOS + latest chipset/Intel DTT drivers)."
    }
    # Core parking - CPUs sleeping between frames add latency in VR
    $val = (powercfg /q SCHEME_CURRENT SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 2>$null |
            Select-String 'Current AC Power Setting Index:\s*(0x\w+)').Matches.Groups[1].Value
    if ($val) {
        $pct = [Convert]::ToInt32($val,16)
        Write-Result 'Min cores unparked (AC)' "$pct%" ($(if ($pct -eq 100){'OK'}else{'WARN'}))
        if ($pct -lt 100) { Add-Finding "Processor min-cores is $pct% (core parking active). For VR set 'Processor performance core parking min cores' to 100% so cores don't sleep between frames." }
    }
} catch { Write-Result 'CPU topology' "Error: $_" 'WARN' }

# ---- Display driver timeouts (TDR) -----------------------------------------
Write-Section 'Display-driver resets (TDR) - VR crash cause'
if ($isAdmin) {
    try {
        $tdr = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Display'; Id=4101} -MaxEvents 10 -ErrorAction Stop
        if ($tdr) {
            foreach ($e in $tdr) { Write-Result 'TDR event' $e.TimeCreated 'WARN' }
            Add-Finding "The display driver has reset (event 4101, 'stopped responding and recovered') $($tdr.Count) time(s). In VR this shows as a freeze/black flash or CTD. Causes: unstable GPU overclock/undervolt (test at stock), driver version (clean-install with DDU), or VRAM/power. Correlate the timestamps with your sessions."
        } else { Write-Result 'TDR events' 'None recorded' 'OK' }
    } catch { Write-Result 'TDR scan' 'None found' 'OK' }
} else { Write-Result 'TDR scan' 'Skipped (needs admin)' 'WARN' }

# ---- Per-app GPU preference ------------------------------------------------
Write-Section 'Per-app GPU preference (High performance on the 4090)'
try {
    $pref = Get-ItemProperty 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -ErrorAction Stop
    $apps = $pref.PSObject.Properties | Where-Object { $_.Name -match 'FlightSimulator|acs|assettocorsa|steamvr|vrserver' }
    if ($apps) {
        foreach ($a in $apps) {
            $hp = $a.Value -match 'GpuPreference=2'
            Write-Result ([IO.Path]::GetFileName($a.Name)) ($(if ($hp){'High performance'}else{$a.Value})) ($(if ($hp){'OK'}else{'WARN'}))
        }
    } else {
        Write-Result 'Game GPU preferences' 'Not explicitly set (OS auto)' 'INFO'
        Add-Finding 'No explicit High-performance GPU preference set for the sims. Harmless on a single-GPU box, but if an iGPU is ever enabled the game can pick it. Settings > Display > Graphics > add the game .exe > High performance.'
    }
} catch { Write-Result 'GPU preferences' 'None configured' 'INFO' }

# ---- MSFS config discovery -------------------------------------------------
Write-Section 'MSFS configuration (if found)'
$cfgPaths = @(
    "$env:APPDATA\Microsoft Flight Simulator\UserCfg.opt",
    "$env:APPDATA\Microsoft Flight Simulator 2024\UserCfg.opt",
    "$env:LOCALAPPDATA\Packages\Microsoft.FlightSimulator_8wekyb3d8bbwe\LocalCache\UserCfg.opt",
    "$env:LOCALAPPDATA\Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt"
)
$cfg = $cfgPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($cfg) {
    Write-Result 'UserCfg.opt' $cfg 'OK'
    $txt = Get-Content $cfg -Raw
    foreach ($k in 'InGameUiZoomScale','TerrainLOD','ObjectsLOD') {
        if ($txt -match "$k\s+([\d.]+)") { Write-Result $k $Matches[1] }
    }
    if ($txt -match 'RollingCachePath\s+"([^"]+)"') {
        $rc = $Matches[1]
        $drive = (Get-Item $rc -ErrorAction SilentlyContinue).PSDrive.Name
        Write-Result 'Rolling cache path' $rc
    }
} else {
    Write-Result 'UserCfg.opt' 'Not found in known locations' 'INFO'
}

# ---- Startup / background load ---------------------------------------------
Write-Section 'Auto-start programs (FPS/latency stealers)'
$runKeys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
           'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$noisy = 'iCUE|Corsair|Aura|LightingService|RGBFusion|Razer|Synapse|Wallpaper|Discord|Epic|Steam|OneDrive|Adobe|Spotify|Nahimic|MSI'
foreach ($rk in $runKeys) {
    try {
        (Get-ItemProperty $rk -ErrorAction Stop).PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                $flag = if ($_.Value -match $noisy -or $_.Name -match $noisy) { 'WARN' } else { 'INFO' }
                Write-Result $_.Name ($_.Value -replace '^"?([^"]*)".*','$1') $flag
            }
    } catch { }
}
Add-Finding 'Review the auto-start list above. RGB suites (iCUE/Aura/RGBFusion), Razer Synapse, Nahimic, Wallpaper Engine and Discord overlays are the usual VR stutter sources - disable their auto-start or close them before sessions (Task Manager > Startup).'

# ---- USB port of the headset -----------------------------------------------
Write-Section 'USB - where the Crystal is attached'
try {
    Get-PnpDevice -Class USB -ErrorAction Stop | Where-Object { $_.FriendlyName -match 'USB' } |
        ForEach-Object {
            $speed = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -ErrorAction SilentlyContinue).Data
        }
    $hubs = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'USB' -and $_.Status -eq 'OK' }
    Write-Result 'USB devices OK' ($hubs | Measure-Object).Count 'OK'
    Add-Finding 'The Crystal wants a high-bandwidth port. Prefer a rear USB 3.x port wired directly to the motherboard (not a front-panel header or a hub). If you see intermittent drops, try the ports nearest the I/O panel and avoid sharing a controller with other bandwidth-heavy USB devices.'
} catch { Write-Result 'USB enumeration' "Error: $_" 'WARN' }

# ---- Latency-relevant settings ---------------------------------------------
Write-Section 'Latency / timer settings'
try {
    $bcd = bcdedit /enum '{current}' 2>$null
    $useplatform = ($bcd | Select-String 'useplatformclock').Line
    Write-Result 'bcd useplatformclock' ($(if ($useplatform){$useplatform.Trim()}else{'not set (good - dynamic tick)'})) ($(if ($useplatform){'WARN'}else{'OK'}))
    if ($useplatform) { Add-Finding 'bcdedit useplatformclock is set (forces HPET). On modern systems this usually HURTS latency/FPS. Remove it: bcdedit /deletevalue useplatformclock.' }
} catch { }
try {
    $mmcss = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -ErrorAction Stop
    Write-Result 'SystemResponsiveness' $mmcss.SystemResponsiveness ($(if ($mmcss.SystemResponsiveness -le 10){'OK'}else{'INFO'}))
} catch { }

# ---- Summary ---------------------------------------------------------------
Write-Section 'Summary'
if ($findings.Count -eq 0) {
    Write-Host 'Nothing flagged. For the numbers that matter, re-run the GPU telemetry section while flying/driving.' -ForegroundColor Green
} else {
    for ($i=0; $i -lt $findings.Count; $i++) {
        Write-Host ("{0}. {1}" -f ($i+1), $findings[$i]) -ForegroundColor Yellow
        Write-Host ''
    }
}
Write-Host 'Tip: run this from a local Claude Code session and ask it to re-probe anything flagged - it can sample under game load and correlate live.' -ForegroundColor DarkGray
