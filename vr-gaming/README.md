# VR readiness & resource report for the Pimax Crystal

You asked for a scan of the computer's resources and overall health to
support VR gaming on a Pimax Crystal at the highest framerate, which is
currently resource-restricted.

**Important:** this has to run on the *actual gaming PC*. The script that
generated your repo session runs in a throwaway Linux cloud container with
no GPU and no view of your hardware, so it cannot scan the real machine.
This script is the thing that does the scan - run it locally on the gaming
PC and it prints the report.

## Why the Crystal is so demanding

The Crystal renders **2880 x 2880 per eye** (two QLED panels, local
dimming) at up to **120 Hz** (160 Hz on the Crystal Super), over
**DisplayPort 1.4 with DSC**. That is ~16.6 million native pixels per
frame before any SteamVR supersampling. "Highest framerate" on this
headset is therefore almost always **GPU-bound**, which is why the report
weights the GPU (and its VRAM) above everything else.

## What's in here

- `Get-VRReadiness.ps1` - read-only PowerShell scan. It inventories GPU
  (real VRAM via the driver registry, not the 4 GB-capped WMI value),
  driver age, and **NVIDIA deep telemetry via nvidia-smi** (PCIe link
  width, power draw vs limit, clocks, throttle reasons); CPU; RAM
  (capacity + single/dual-channel); pagefile; storage type and free space;
  the DisplayPort path and active resolution/refresh; USB controllers;
  power plan + USB selective suspend; HAGS / Game Mode / Game DVR; Memory
  Integrity (VBS); thermals; live background resource hogs; Resizable BAR
  guidance; and the installed VR stack (Pimax Play / SteamVR / OpenXR
  Toolkit).

  It also runs a **driver-health and capacity audit**: devices Windows
  flags with a non-OK driver status (the Device Manager yellow "!"), the
  versions/dates of the drivers in the VR path (Display, USB, Net, System
  chipset, storage) with anything 3+ years old flagged, every startup
  entry, and the always-on vendor/RGB/telemetry services (Razer, Corsair,
  Armoury, Nahimic, NVIDIA telemetry, ...) that add DPC latency and
  microstutter. It ends with a **prioritized, numbered list of fixes**
  sorted CRITICAL -> LOW.

  With `-MonitorSeconds N` it adds a **live load capture**: run a
  demanding VR scene while it samples GPU/CPU utilization, VRAM,
  temperature, power, and throttle reasons, then prints a **bottleneck
  verdict** - GPU-bound vs CPU-bound vs power/thermal/VRAM-limited. That
  verdict is the thing that actually answers "what is restricting my
  framerate".

It changes nothing. Every recommendation is printed for you to apply.

## Run it

On the gaming PC, in an **elevated** PowerShell (Run as Administrator):

```powershell
powershell -ExecutionPolicy Bypass -File .\Get-VRReadiness.ps1
```

Save a copy of the report to a file to share or keep:

```powershell
.\Get-VRReadiness.ps1 -ReportPath .\vr-report.txt
```

Capture the live bottleneck (the important one). Launch this, then
immediately put the headset on and load a heavy scene for the whole
window:

```powershell
.\Get-VRReadiness.ps1 -MonitorSeconds 30
```

Combine both - run a live capture and save the whole report:

```powershell
.\Get-VRReadiness.ps1 -MonitorSeconds 30 -ReportPath .\vr-report.txt
```

Elevation matters for the power-plan and some driver/firmware queries; it
still runs without admin but will say those sections are incomplete. The
live capture's GPU telemetry is richest on NVIDIA (nvidia-smi); on AMD it
falls back to Windows GPU performance counters for utilization.

## How to read the output

The Summary at the bottom is the part that matters. Work it top-down -
CRITICAL and HIGH findings are what is actually restricting your
framerate. On the Crystal the order of impact is almost always:

```
GPU  >  VRAM  >  RAM (dual-channel)  >  CPU  >  OS / power settings
```

If the scan comes back clean but framerate is still capped, the limiter
is inside the VR software, not the hardware - lower the per-eye **Render
Quality** in Pimax Play, pick a refresh rate the GPU can actually sustain
(90 Hz is often the sweet spot vs 120/160), turn off SteamVR
auto-resolution and set a manual render resolution, and lean on
**DLSS/DLAA + Quad-Views / fixed-foveated rendering** - the single biggest
framerate win on this headset.

## What this script does NOT do

- It does not read the headset's actual in-game FPS or per-frame
  reprojection - only the runtime knows that. Pair the live verdict with
  the **SteamVR frame-timing** overlay to see dropped/reprojected frames
  directly. (The live capture *does* tell you whether the GPU or CPU is
  the limiter, which is the part most people guess wrong.)
- Resizable BAR is not reliably readable from script, so it points you to
  GPU-Z / NVIDIA Control Panel to confirm it rather than guessing.
- ACPI thermal zones are coarse; the live capture uses nvidia-smi's real
  GPU temperature on NVIDIA, but for AMD use GPU-Z/HWiNFO64 alongside it.
