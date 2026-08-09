# Doom C64U — Architecture And Design Intent

> **What this document is.** This is the *target* architecture: the engine the
> project is aiming at, and the reasoning behind its shape. It is deliberately
> ahead of the code.
>
> For the pipeline **as actually implemented** — with real formulas, real cycle
> counts and a frame traced end to end — see **[`pipeline.md`](pipeline.md)**.
> For what is built and what is next, see
> [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md).
>
> What exists today renders a visible frame from a 3-sector test map: per-column
> clip windows, flat-shaded walls/floors/ceilings and the multicolor converter.
> It does **not** yet implement REU streaming, PVS visibility, textures, sprites,
> audio or quality scaling. One decision below has already been overtaken by the
> code: traversal. This document's portal-graph-of-convex-sectors model is what
> `src/render/walls.asm` implements, but it cannot express real Doom geometry, so
> Milestone 1 replaces it with a **front-to-back BSP walk** over the WAD's own
> `NODES` — see `IMPLEMENTATION_PLAN.md` §3 for the reasoning. Where the implementation deliberately diverges from
> this document — notably in the numeric formats, see the *Implementation note*
> in the Preface below — `pipeline.md` §2 and §14 record the difference and the
> reason.

## Preface

This project targets a unique machine profile: a Commodore 64 Ultimate platform with a 6510-compatible CPU running at up to 64 MHz and 16 MB of REU memory. The objective is to design a Doom-like engine that is not a direct clone, but a hardware-aware reinterpretation: mathematically grounded, deterministic, and aggressively optimized for this architecture.

The central design principle is to treat the engine as a throughput pipeline rather than a collection of isolated features. Geometry transform, visibility, wall span generation, texture address calculation, lighting, and final raster writes must be arranged so each stage is predictable in timing and memory access. On this class of hardware, consistency and cache-like locality effects from tight loops matter more than algorithmic elegance alone.

The mathematical foundation is fixed-point first. Floating point is avoided in the runtime renderer. The world is represented in 2D sectors and linedefs with height intervals (classic 2.5D model), while camera and projection math use pre-scaled fixed-point formats selected per subsystem:

- World and camera coordinates: signed 16.16 fixed point.
- Angles: unsigned turn space (0..65535 for full rotation).
- Trigonometric lookup tables: quantized sin/cos with interpolation only where needed.
- Projection terms: precomputed reciprocal and tangent tables to remove divisions from hot paths.

> **Implementation note (Milestone 1).** The code currently uses **signed
> 16-bit integer** world coordinates and an **8-bit** angle (0..255 per turn),
> not 16.16 and 0..65535. This halves the cost of every transform multiply and
> lets the angle wrap for free in a register, at the cost of no sub-unit motion
> and 1.406° of angular granularity. The 2.14 sine table is already in its final
> form, so widening the angle is an indexing change, not a data change.
> Projection still uses runtime division (`udiv`) rather than reciprocal tables;
> at ~880 cycles per divide and ~6 divides per wall this is measurable but not
> yet dominant — see `pipeline.md` §12.1, where geometry is 13% of the frame and
> the two byte-per-pixel passes are 75%.

From this model, each frame is produced by a deterministic sequence:

1. Transform sector-visible edges into camera space.
2. Clip against near plane and horizontal field boundaries.
3. Project to screen columns using reciprocal-based perspective.
4. Resolve occlusion front-to-back with a column clip buffer.
5. Draw vertical wall spans and deferred floor/ceiling spans.

The optimization strategy is built around the C64U asymmetry: CPU time is precious per frame, but REU capacity is abundant.

- REU is used as a high-capacity streaming store for maps, texture pages, precomputed visibility sets, and optional animation/state buffers.
- Main memory holds only hot working sets: current sectors, active draw lists, clip buffers, and scanline/column state.
- Data layouts are structure-of-arrays where possible to maximize linear memory access in inner loops.
- Large assets are chunked into page-aligned blocks so transfers can be scheduled and overlapped with non-dependent CPU work.

The runtime profile is constrained by explicit platform goals:

- Target frame rate is 25 FPS, with frame-time stability prioritized over peak instantaneous speed.
- Music playback is part of the baseline workload (reference track: https://csdb.dk/release/?id=205284), so render budgets account for audio update cost.
- Display mode is multicolor 160x200, and projection/raster precision is tuned to that effective resolution rather than to full hi-res assumptions.
- Main memory budget is 64 KB only; BASIC and KERNAL are switched off during gameplay to maximize available RAM.
- DMA is the primary path for data transfers between REU and active working memory.
- Pipeline stages are precomputed as much as possible (lookup tables, quantized projection terms, visibility helpers), leveraging low resolution to reduce the need for overly accurate per-pixel math in hot loops.
- VIC-II hardware sprites are not used as in-scene entities; sprite imagery is treated as blitted scene content copied by DMA, with sprite assets stored in REU in multiple pre-sized variants.

Performance targets are expressed in frame budget terms, not only in average FPS. The renderer should preserve frame-time stability under stress (dense sectors, many visible edges, and high motion) by combining strict culling, bounded per-column work, and quality scaling options (distance-based texture detail, reduced lighting precision, or span skipping at extreme depth).

Visual quality may trade off display accuracy in controlled, deterministic ways: coarser depth/light quantization, reduced texture sampling precision at distance, and selective span decimation in far geometry. These trade-offs are designed to preserve responsiveness and temporal stability before preserving fine spatial detail.

This document therefore focuses on three complementary goals:

- A practical engine architecture that maps cleanly to 6510-era constraints.
- A mathematical model that minimizes expensive operations in runtime loops.
- A memory/streaming model that turns 16 MB REU into sustained rendering throughput.

If these goals are met, the resulting engine will demonstrate that a Doom-like experience on C64 Ultimate is not only feasible, but can be technically disciplined, scalable, and surprisingly fluid when the math and data flow are designed for the machine from the start.

## Compute Pipeline

> The six stages below are the *target* decomposition. The implemented pipeline
> collapses some of them — scene calculation and rasterization are fused, and
> there is no draw-command queue — and omits others entirely. **[`pipeline.md`](pipeline.md)**
> traces the real thing stage by stage; its §14 maps each of the stages below
> onto what exists today.

The compute pipeline must be organized around bounded work per frame, not around idealized full-scene accuracy. On C64U, the renderer cannot afford to rediscover the whole world every frame from scratch, nor can it treat texturing or sprite-like objects as independent expensive passes. The viable approach is to move from camera state to a tightly filtered visible working set, then to column-oriented wall and sprite generation, while keeping DMA, REU streaming, and main-memory residency predictable.

Large REU capacity should be used to hold the broad lookup universe: trigonometric tables, reciprocal tables, projection tables, coarse visibility tables, texture indirection tables, pre-dithered material variants, and pre-sized billboard assets. RAM should hold only the small active slices needed for the current frame window. The design objective is not to make every lookup resident, but to guarantee that the subset required by the current camera state can be fetched into RAM deterministically.

### 1. Camera State And Frame Setup

Each frame begins by reducing camera state to the small set of values the rest of the pipeline needs: camera position, facing angle, sector membership, pre-scaled view vectors, horizon offset, and movement state. This stage should also resolve which map chunks, texture pages, and actor pages must be resident for the next frame or two, because late asset fetches are more damaging than slightly stale prefetches.

Optimizations at this stage:

- Keep camera math entirely in fixed-point, with sin/cos, reciprocal, and view-plane terms fetched from tables rather than recomputed.
- Track the current sector incrementally so sector lookup is usually an adjacency walk, not a global search.
- Quantize view angle and horizon into coarse buckets for table reuse; sub-degree precision is wasted at 160x200 multicolor output.
- Use camera velocity and turn rate to drive speculative REU prefetch of neighboring sectors and likely texture pages.
- Prebuild per-angle projection constants so the rest of the frame can avoid setup divisions entirely.

### 2. Scene Visibility Reduction

The next step is not full rendering, but aggressive rejection. Starting from the camera sector, the engine should walk only potentially visible neighboring sectors, applying portal-style traversal and rejecting geometry that cannot contribute on the current screen. This is the stage that protects the rest of the pipeline from pathological maps.

Classic Doom relies heavily on offline binary partitioning and lookup-driven traversal, especially through its BSP tree and angle/texture tables. That general lesson remains valid here: binary partitioning is useful if it reduces runtime decision cost. On C64U, however, the runtime structure should stay compact and sector-oriented, with any BSP-like split data serving as an offline aid for visibility ordering, coarse PVS generation, or map chunking rather than as a deep pointer-chasing structure that expands RAM pressure.

Optimizations at this stage:

- Use precomputed sector adjacency and coarse potentially visible sets stored in REU to cap traversal fan-out.
- Keep REU-hosted visibility tables segmented by region or supersector so only relevant lookup blocks are DMA-fetched into RAM.
- Clip portal windows as traversal proceeds so child sectors inherit narrower screen-space bounds and therefore less downstream work.
- Reject linedefs behind the near plane or outside horizontal field bounds before any expensive per-column projection.
- Apply distance buckets and screen-width thresholds so very small or very distant walls can fall back to coarse treatment or be skipped entirely.
- Keep a strict limit on active sectors and visible edges per frame; if the cap is reached, degrade deterministically rather than letting frame time spike.

### 3. Scene Calculation And Column Work Generation

Once the visible set is reduced, the engine converts it into bounded column work: projected wall intervals, occlusion updates, floor and ceiling span descriptors, and sprite candidate slots. This stage should be front-to-back wherever possible so the column clip buffer can eliminate hidden work early. The goal is not to generate a perfect scene graph, but a compact draw workload already shaped to the raster format.

Optimizations at this stage:

- Project edges with reciprocal lookup tables and incremental stepping across columns instead of repeated divide-like operations.
- Maintain a per-column clip buffer so fully occluded walls terminate early and never reach the texturing stage.
- Store wall descriptors in structure-of-arrays form to support tight linear loops during generation and draw.
- Quantize depth and lighting during descriptor generation so later stages consume small integer indices instead of raw world-space values.
- Defer floor and ceiling work into span records rather than drawing immediately; this keeps the hot wall path short and predictable.
- For stress cases, allow far-depth span decimation or coarse column stepping as an explicit frame-stability fallback.

### 4. Texturing And Lighting Application

Texturing must be subordinate to memory locality. A C64U-feasible renderer cannot afford arbitrary texel access with high precision on every sample. Instead, texture fetches should operate on resident pages, use column-friendly addressing, and lean on prequantized lighting so the inner loops are mostly indexed loads, bit packing, and writes.

Textures should therefore be authored and stored as highly repeatable small patches, not as large unique images. The RAM texture cache should be explicitly capped so memory consumption and DMA bandwidth stay predictable under stress. Repetition is not just an art constraint here; it is a compute strategy that allows reuse of a small set of material pages, lighting variants, and layout transforms.

Optimizations at this stage:

- Organize texture data in REU and RAM by draw orientation and page alignment so vertical wall sampling is mostly sequential.
- Cap the RAM texture cache to a fixed page budget and use a simple deterministic replacement policy driven by sector locality and recency.
- Use pre-scaled texture-step increments per projected column to avoid recomputing texture coordinates at every pixel.
- Quantize lighting into a small number of bands with prederived palette or pattern variants, removing per-pixel light math.
- Prefer ordered dither patterns or precomputed stipple variants over error-diffusion dithering; error diffusion is too branchy and stateful for the hot path and tends to shimmer at low resolution.
- Treat multicolor's 4-colors-per-8x8 constraint as a material encoding problem: preprocess textures into tile-compatible variants, assign palette groups per sector or material family, and allow distance-based fallback to flatter pattern fills when a tile cannot support the desired local contrast.
- Reduce sampling precision with distance: nearby walls can use denser stepping, while distant walls can reuse texels or sample every other row.
- Keep hot texture pages resident across frames based on recent visibility history instead of reloading strictly on demand.
- Store pre-dithered texture and lighting variants in REU so the renderer chooses among prepared assets instead of synthesizing patterns per frame.
- Prefer lookup-assisted multicolor packing paths that write directly in display-native form, avoiding intermediate high-precision buffers.

### 5. Sprites, Actor Billboards, And Blitted Objects

Sprite-like scene elements must be treated as bounded billboard workloads, not as a second free-form renderer. Because VIC-II hardware sprites are reserved out of the scene model, actors, pickups, and effects should be stored as pre-sized blit assets in REU and inserted only after the wall visibility pass has already constrained where they can appear.

Optimizations at this stage:

- Reduce actor rendering to camera-relative billboard transforms with coarse scale buckets, using pre-sized image variants instead of runtime scaling.
- Reuse the wall depth and column clip information to reject fully hidden sprites before any blit preparation.
- Sort only the surviving sprite set, and cap it aggressively; a deterministic sprite budget is more important than drawing every actor in dense encounters.
- Store multiple orientation frames and scale variants in REU so the CPU mostly selects assets rather than synthesizing them.
- Use bounding-column masks to skip transparent runs and to limit blits to visible screen slices.
- For low-priority effects, allow temporal decimation such as updating every second frame when motion and depth make the loss acceptable.

### 6. Raster Commit And Video Memory Update

The final stage converts the prepared column and span results into the actual VIC-II-visible buffers. A double-buffer or bank-switched layout is appropriate, but the cost model must include both bitmap/screen writes and the separate update path for $D800 color RAM. This stage is where all prior quantization decisions pay off: if wall, floor, and sprite descriptors already map cleanly to display-native encoding, the commit step becomes a bounded memory copy and pack operation instead of another renderer.

Optimizations at this stage:

- Render into an off-screen bitmap and screen buffer in the selected bank, then flip only when the full frame is coherent.
- Treat $D800 color memory as a first-class output surface with its own compact update records; do not bolt color writes on after bitmap generation.
- Build per-tile dirty masks during earlier stages so only changed character cells and color nybbles are committed.
- Separate bitmap, screen RAM, and color RAM packing into cache-friendly linear passes rather than interleaving all write types in one complex loop.
- Use lookup tables for multicolor byte packing and color selection so final commit is mostly indexed stores.
- Where map and lighting style allow it, stabilize tile colors across neighboring cells to reduce $D800 churn and visible flicker.
- Schedule DMA-assisted transfers for prepared backbuffer regions when it is faster than CPU copying, but keep the transfer granularity coarse and predictable.

In this model, the compute pipeline is successful only if each stage shrinks and regularizes the work for the next one. Camera setup predicts what data must be hot, visibility keeps the active world small, scene calculation turns geometry into bounded column jobs, texturing consumes those jobs with locality-aware fetches, sprite handling remains a capped billboard pass shaped by the same occlusion data, and the final raster commit writes directly into VIC-II-facing memory with bounded bitmap and $D800 update cost. That is the form of pipeline that fits the C64U: deterministic, table-driven, memory-conscious, and willing to trade precision for stable throughput.
