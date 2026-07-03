# Machine report — Check-VrPerformance.ps1 results (2026-07-03)

Hardware surveyed: i9-12900K (16C/24T) · 96 GB DDR5-5600 dual-channel (XMP
active) · RTX 4090 @ PCIe 4.0 x16, driver 2026-06 · MSFS-capable NVMe (990
Pro 4TB + P3 Plus 4TB) · Pimax native OpenXR runtime active, PimaxXR +
OpenXR Toolkit installed.

**Verdict: the hardware is not the problem.** Nothing is misconfigured in a
way that costs meaningful FPS. Gains from here come from settings, and the
long-term ceiling is the CPU, not the 4090.

## Do now (free)

1. **Turn off Game DVR** — Settings → Gaming → Captures → disable
   "Record what happened". Only real flag the scan raised.
2. **Verify HAGS is on** — the registry key was unset (OS default).
   Settings → System → Display → Graphics → Change default graphics
   settings → Hardware-accelerated GPU scheduling = On. Needed for DLSS
   Frame Generation in MSFS 2024.
3. **Pause OneDrive** during VR sessions (it was running).

## MSFS: plan around the 12900K

The 12900K is a capable chip but it is the weakest link in this system for
MSFS VR — expect "Limited by MainThread" in dev mode over photogrammetry
cities, and no resolution setting will change that.

- Pimax at **72 Hz**, render quality 1.0, small FOV.
- **TLOD 100–150**, Objects LOD 100, AI/road/boat traffic low — these are
  the levers that actually move a main-thread limit.
- DLSS Quality + (if the headset is a Crystal-family with eye tracking)
  **Quad Views Foveated Rendering** to keep the GPU side trivial.
- OpenXR Toolkit is already installed — use its overlay to confirm whether
  CPU or GPU frame time is over budget before touching anything else.

## Assetto Corsa: check the VR path

SteamVR was **not found** in the default Steam location. AC is an OpenVR
game, so it needs either:

- SteamVR (fine if Steam lives on another drive — the scan only checked
  `C:\Program Files (x86)\Steam`), or
- **OpenComposite** pointed at PimaxXR — recommended; skips the SteamVR
  compositor entirely and pairs with the runtime already active.

With the 4090 GPU-bound in AC, cap CSP mirror resolution and screen-space
effects first, then spend leftover headroom on ~1.2× supersampling.

## Upgrade advice

Nothing urgent. The only upgrade that would matter is a platform swap to a
**Ryzen 7 9800X3D** (new board + DDR5), worth roughly 30–50% in
main-thread-bound MSFS scenes. Do it only if, after the tuning above, the
dev-mode counter still shows MainThread-limited below your FPS target.
Everything else (RAM, storage, PCIe, drivers) is already at or above what
the sims can use.
