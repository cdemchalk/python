# VR FPS Optimization — Pimax + RTX 4090

Target games: **Microsoft Flight Simulator** and **Assetto Corsa** (incl.
Competizione). Companion to `Check-VrPerformance.ps1`, which inventories the
hardware/OS side. This document covers what the script can't see: headset,
runtime, and in-game settings.

---

## 1. Understand what's actually limiting you (do this first)

A 4090 is almost never the whole story on a Pimax. The two games fail
differently:

- **MSFS is usually CPU main-thread bound.** Open dev mode
  (Options → General → Developers) and enable the FPS counter. If it says
  **"Limited by MainThread"**, no graphics/resolution setting will help —
  only CPU-side changes (TLOD, traffic, X3D CPU) will.
- **Assetto Corsa is usually GPU bound** at Pimax resolutions, and it's an
  old, lightly-threaded engine — a strong single core plus GPU headroom.

Tools:
- **fpsVR** (Steam, ~$4) — frametime graphs for CPU vs GPU inside the headset.
- **OpenXR Toolkit overlay** — same for OpenXR games (MSFS).
- Rule: fix whichever frametime line is over budget (11.1 ms @ 90 Hz,
  13.9 ms @ 72 Hz), not both.

---

## 2. Pimax settings (Pimax Play)

These have the largest single impact because Pimax panels are enormous
(Crystal: 2880×2880 per eye — ~2.4× the pixels of a Quest 3).

| Setting | Recommendation | Why |
|---|---|---|
| Refresh rate | **72 Hz** for MSFS, 90 Hz for Assetto Corsa | 72 Hz gives you 13.9 ms of frame budget instead of 11.1 — a free ~25% headroom. Flight sims don't need 90. |
| Render quality | **1.0** | Above 1.0 explodes pixel count for marginal clarity. Sharpen in OpenXR Toolkit instead. |
| FOV | **Reduced/Small** for sims | You're in a cockpit; the outer FOV is bezel. Large→Small FOV can cut rendered pixels 20–30%. |
| Smart Smoothing / motion compensation | Off if you hold native FPS; on as a last resort | Reprojection artifacts are visible on props and fences. Prefer lowering settings to holding fake frames. |
| Hidden area mask | On | Skips pixels the lenses can't show. |

**Crystal / Crystal Light / Super with eye tracking:** enable **Dynamic
Foveated Rendering**, and for MSFS use **Quad Views Foveated Rendering**
(quad-views-foveated by mbucchia). On a Crystal this is the single biggest
MSFS win available — commonly **+30–50% GPU headroom** with no visible loss,
because only where you're looking renders at full resolution.

---

## 3. OpenXR runtime (MSFS)

- Use **PimaxXR / Pimax's native OpenXR runtime**, *not* SteamVR, as the
  active OpenXR runtime. SteamVR adds a second compositor and measurable
  frame time. The diagnostic script checks which one is active.
- Install **OpenXR Toolkit** (mbucchia): use **CAS sharpening ~50–70%** so
  you can run lower render resolution without mush, and its FPS overlay.
  Note: OpenXR Toolkit is unsupported in MSFS **2024** — there, use the
  in-sim DLSS + quad-views instead.

Assetto Corsa is OpenVR: it runs through SteamVR (or OpenComposite to skip
it). If you stay on SteamVR, set per-app resolution there to 100% and do
your supersampling in one place only — never stack Pimax quality × SteamVR
SS × in-game SS.

---

## 4. Microsoft Flight Simulator settings

The order of impact in VR:

1. **DLSS Quality** (2024: DLSS + Frame Generation where supported) instead
   of TAA. On a Crystal-class panel DLSS Quality looks close to native and
   saves ~30% GPU. If glass-cockpit text ghosting bothers you, DLAA or TAA
   at ~80% render scale are the fallbacks.
2. **Terrain Level of Detail (TLOD) 100–150.** This is the #1 *CPU* lever.
   200+ in VR is how people get 25 FPS over cities. Off-load with
   photogrammetry off in dense cities if main-thread bound.
3. **Objects LOD 100.** Traffic: AI/multiplayer aircraft, ground vehicles,
   and boat traffic all cost main-thread — keep low.
4. Volumetric clouds **Medium/High** (Ultra is a huge GPU hit in VR).
5. Glass cockpit refresh rate **Medium**.
6. Off-screen terrain pre-caching **Ultra** (uses RAM to reduce stutter).
7. **DX12** on a 4090 (needed for Frame Gen in 2024); if you see artifacts
   in 2020, DX11 is still fine.
8. Rolling cache on NVMe, ~64 GB, if your internet is fast; disable it if
   on slow storage.
9. Render scale 100 in-game — resolution is controlled at the Pimax/OpenXR
   layer, one knob only.

---

## 5. Assetto Corsa settings

Original AC (with Content Manager + CSP, which you should be using):

- **CSP Graphics adjustments:** cap "Mirrors resolution" (huge, often
  overlooked VR cost), turn real mirrors on but low; smoke/particles ≤ 50%;
  disable "Extra FX" screen-space effects in VR (SSLR/SSAO are expensive
  and shimmer in stereo).
- **World detail High not Maximum**, shadows Medium/High (shadow resolution
  is a big VR cost), reflections Low/Static faces, "reflection rendering
  frequency" reduced.
- AC is CPU-light: with a 4090 you'll often have headroom to **supersample
  ~1.2–1.3×** for grid legibility — but add it only after you hold your
  refresh rate on a full grid at night in rain (worst case), and add it in
  exactly one layer (SteamVR per-app or Pimax quality).
- **ACC** is far heavier: DLSS Quality, shadows Mid, foliage low, mirrors
  low, and expect to run 90 Hz only with modest resolution.
- Consider **OpenComposite** to run AC without SteamVR on PimaxXR — saves a
  few ms of compositor overhead; test both.

---

## 6. NVIDIA settings (NVIDIA app / Control Panel)

Per-game profiles for the sims:

- Power management: **Prefer maximum performance**
- Low Latency Mode: **On** (not Ultra for VR)
- Threaded optimization: On
- Vertical sync: **Off** (the VR compositor handles sync; in-game vsync off too)
- Texture filtering quality: High performance costs nothing visible in VR
- Don't force MSAA/FXAA globally
- Keep drivers current — VR fixes ship regularly.

Make sure **Resizable BAR** is enabled (BIOS: Above 4G Decoding + ReBAR;
verify in NVIDIA app → System info). Free performance on a 4090.

---

## 7. Windows

The diagnostic script checks all of these; the short list:

- **HAGS on** (required for DLSS Frame Generation), Game Mode on.
- Game Bar background recording **off**.
- Power plan High performance / Ultimate.
- Memory Integrity (Core Isolation) costs ~5% CPU — disabling it is a
  security trade-off you must decide on; it matters most in CPU-bound MSFS.
- XMP/EXPO enabled in BIOS — DDR5-6000 vs JEDEC-4800 is a real MSFS gain.
- Kill RGB suites (iCUE/Aura), Wallpaper Engine, and overlays while in VR.

---

## 8. Hardware upgrade priority (if settings aren't enough)

With the 4090 fixed, in order of $/FPS for these two sims:

1. **CPU → Ryzen 7 9800X3D (or 7800X3D).** MSFS and AC both love 3D
   V-Cache; this is the only upgrade that fixes "Limited by MainThread".
   If you're on anything older than a 12th-gen Intel / Ryzen 5000, this is
   where your FPS went.
2. **RAM → 64 GB dual-channel** (DDR5-6000 CL30 on AM5). MSFS +
   photogrammetry + rolling cache is a memory hog.
3. **NVMe** for MSFS + AC content if either lives on SATA/HDD — fixes
   stutter and pop-in more than average FPS.
4. **Eye-tracked Pimax** (Crystal-family) if you're on a non-eye-tracked
   model — dynamic foveated rendering is effectively a GPU-tier upgrade
   for free, forever.
5. PSU/cooling sanity: a 4090 + hot CPU throttling mid-flight looks exactly
   like a settings problem. Check clocks under load with HWiNFO.

**Not worth it:** a second GPU (VR SLI is dead), >64 GB RAM, PCIe 5.0
anything (the 4090 is Gen 4 and doesn't saturate it).

---

## 9. A sane tuning workflow

1. Run `Check-VrPerformance.ps1`, fix everything it flags.
2. Pimax Play: 72 Hz (MSFS) / 90 Hz (AC), quality 1.0, small FOV, DFR on
   if eye-tracked.
3. Set the games to the baselines above.
4. Fly/drive the *worst case* (JFK at dusk in MSFS; full grid, night, rain
   in AC) with the frametime overlay up.
5. If GPU-bound: lower render resolution / clouds / mirrors, or enable
   quad-views. If CPU-bound (MSFS): lower TLOD and traffic — resolution
   changes will do nothing.
6. Only once you hold refresh rate in the worst case, spend leftover
   headroom on supersampling or higher refresh.
