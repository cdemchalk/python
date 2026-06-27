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
  driver age, CPU, RAM (capacity + single/dual-channel), storage type and
  free space, the DisplayPort path, USB controllers, power plan + USB
  selective suspend, HAGS / Game Mode / Game DVR, Memory Integrity (VBS),
  thermals (best-effort), live background resource hogs, and the installed
  VR stack (Pimax Play / SteamVR / OpenXR Toolkit). It ends with a
  **prioritized, numbered list of fixes** sorted CRITICAL -> LOW.

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

Elevation matters for the power-plan and some driver/firmware queries; it
still runs without admin but will say those sections are incomplete.

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

- It does not measure in-game FPS or GPU frametimes under load. For that,
  run a session with the **SteamVR frame-timing** overlay or **HWiNFO64**
  and watch for the GPU pegged at ~100% (GPU-bound) vs the CPU frame line
  spiking (CPU-bound).
- It does not confirm real temperatures under load - ACPI zones are
  coarse. Use HWiNFO64 / GPU-Z during a VR session to rule out thermal or
  power throttling.
