# CPU upgrade analysis — pairing a CPU to your 4090 for MSFS VR

Your situation: **MSFS repeatedly reports "Limited by MainThread"** in VR on an
i9-12900K + RTX 4090 + Pimax Crystal. That single fact drives everything below:

- When you are main-thread bound, **the CPU sets your FPS ceiling** and the
  4090 sits partly idle. A GPU upgrade would do nothing; a CPU upgrade raises
  the ceiling almost directly.
- MSFS is unusually **cache-sensitive** — it responds to L3 cache far more
  than most games. That's why AMD's **3D V-Cache ("X3D")** chips dominate this
  sim specifically, beating higher-clocked Intel parts.

## The short list (matched to a 4090 for MSFS)

| CPU | Why | Notes |
|---|---|---|
| **Ryzen 7 9800X3D** | **The pick.** Fastest mainstream gaming CPU; top MSFS performer. Strong clocks *and* the big cache, so no VR-cache-miss stutter. | 8 cores/16 threads, AM5. Sweet spot of price/performance. |
| Ryzen 7 7800X3D | ~Same MSFS tier, usually cheaper. ~21% behind the 9800X3D at the very top end but still a huge jump over a 12900K. | Best value if you find one discounted. |
| Ryzen 7 9850X3D | Released Jan 2026, ~6% faster than the 9800X3D. | Only worth it if priced close to the 9800X3D — marginal gain. |
| Ryzen 9 9950X3D | Gaming ≈ 9800X3D, but 16 cores for heavy multitasking/productivity. | Needs correct CCD scheduling (games on the V-Cache die). Buy only if you also do MT work. |

**Intel is not the play here.** Even the 14900K trails the X3D chips in MSFS,
LGA1700 is end-of-life, and Arrow Lake (Core Ultra 2) regressed in gaming.
For a MSFS-first build, AM5 + X3D is the clear choice.

## How much FPS would you actually gain?

Grounded in current MSFS benchmark data:

- Independent testing shows the X3D chips deliver on the order of **~40% higher
  frame rates and ~67% less stuttering** than comparable non-X3D CPUs in MSFS.
- The 12900K trails the 14900K by ~20–25% in MSFS, and the 9800X3D beats the
  14900K — so **12900K → 9800X3D is a large jump**, realistically **~30–45%
  higher FPS in the main-thread-bound scenes** where you currently see the
  MainThread callout (dense cities, complex airports, heavy weather).

What that looks like in VR specifically (this matters more than the raw %):

- If you're pinned at, say, ~30–35 FPS main-thread-limited over a big city,
  expect roughly **~45–50 FPS** in the same spot — often the difference
  between "reprojecting and juddery" and "holding a locked 45, or reaching
  toward 72 in lighter areas."
- The **stutter reduction is the bigger felt improvement** — the frametime
  spikes when panning over cities or loading scenery largely go away, because
  they're caused by main-thread cache misses the V-Cache eliminates.
- In cruise / sparse areas you were probably GPU-bound already, so you'll see
  little change there — the gain is concentrated exactly where you hurt now.

Caveat: MSFS **2024** improved multithreading vs 2020, so the gap is somewhat
smaller than the eye-watering 2020-era numbers — but the main thread is still
the limiter, and X3D is still the top performer.

## What the upgrade actually involves (it's a platform swap)

The 12900K is LGA1700; the X3D chips are **AM5**, so this is CPU **+
motherboard**, not a drop-in:

- **Motherboard:** any B650/B650E/X670E (or newer B850/X870) AM5 board.
- **RAM:** DDR5, same as now — your 96 GB DDR5-5600 is **not incompatible** and
  will almost certainly run on AM5. Three caveats, none fatal: (1) it's an
  XMP (Intel) kit, and AMD prefers EXPO — most AM5 boards apply the XMP timings
  anyway, occasionally needing manual tuning; (2) 2×48 GB are high-capacity
  dual-rank DIMMs, which Ryzen's memory controller may not push to full rated
  speed; (3) AM5's latency sweet spot is **DDR5-6000 CL30**, so 5600 is fine but
  slightly off-optimal for MSFS. Reasonable plan: reuse the 96 GB first, and
  only buy a 64 GB DDR5-6000 CL30 EXPO kit later if you want the last few
  percent (64 GB is plenty for MSFS; you don't need 96).
- **Cooler:** most modern coolers include an AM5 bracket — check yours carries
  over rather than rebuying.
- **GPU/PSU/storage:** all carry over unchanged.

### If you keep the existing RAM (CPU + board only)

You keep **almost the entire gain** — roughly **~28–42%** vs the ~30–45% with
an ideal 6000 CL30 kit. Reason: the 9800X3D's 3D V-Cache is what fixes the
main-thread limit, and it also makes MSFS *less* sensitive to RAM speed
(more of the working set stays in cache). The 5600 → 6000 CL30 difference is
only ~2–4% in gaming generally, and smaller than that on an X3D chip. In the
city scenario (~30–35 FPS now) that's ~44–48 FPS instead of ~45–50 — a 1–2 FPS
difference you won't feel. **Not worth buying RAM for.**

The one thing to verify after the build: confirm the kit actually applies its
EXPO/XMP profile and runs at 5600 (check Task Manager / CPU-Z). A 2×48 GB
dual-rank kit that falls back to JEDEC ~4800 would cost ~5–8%; if 5600 won't
hold cleanly, 5200 is still fine — just don't leave it at 4800.

## Bottom line

1. **Buy: Ryzen 7 9800X3D** + an AM5 board + 64 GB DDR5-6000 CL30. Best
   MSFS-per-dollar, and it fixes the exact bottleneck you're hitting.
2. Expect **~30–45% higher FPS in main-thread-limited scenes** and a large
   drop in stutter; little change where you were already GPU-bound.
3. After the swap you can *either* keep the same settings and bank the FPS, *or*
   raise **TLOD / traffic** (the main-thread load) back up and spend the new
   headroom on visual density — your call.
4. Don't overspend on a 9950X3D/9850X3D for gaming alone; the 9800X3D captures
   almost all of the MSFS benefit.

## Sources

- Tom's Hardware — MSFS 2024 PC performance & CPU/GPU testing:
  https://www.tomshardware.com/video-games/pc-gaming/microsoft-flight-simulator-2024-pc-performance-testing-and-settings-analysis-we-tested-23-gpus-the-game-is-even-more-demanding-than-its-predecessor
- MSFS forums — 5800X3D → 9800X3D upgrade benchmarks (2020 & 2024):
  https://forums.flightsimulator.com/t/5800x3d-to-9800x3d-upgrade-msfs2020-2024-benchmarks/701824
- MSFS forums — 9800X3D 21% faster than 7800X3D (1080p highest + turbo):
  https://forums.flightsimulator.com/t/9800x3d-21-faster-than-the-7800x3d-1080p-highest-turbo/663355
- MSFS forums — 9800X3D owners' MSFS 2024 VR experience:
  https://forums.flightsimulator.com/t/9800x3d-owners-would-you-be-so-kind-as-to-share-your-vr-experience-with-2024/671225
- MSFS forums — 9850X3D (~6% faster than 9800X3D, Jan 2026):
  https://forums.flightsimulator.com/t/ryzen-7-9850x3d-6-faster-than-9800x3d-the-world-s-best-gaming-cpu-tests-comparisons-and-rumors/755705
