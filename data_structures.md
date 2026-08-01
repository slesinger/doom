# Doom C64U Data Structures

This document defines how map content, lookup tables, and sprite/billboard assets are represented for a C64 Ultimate target (6510-compatible CPU, up to 64 MHz, 16 MB REU, 64 KB main RAM).

Design goals:

- Deterministic frame time first, peak visual quality second.
- Keep hot loops linear and branch-light.
- Use REU for capacity and streaming, RAM for active working sets.
- Favor structure-of-arrays (SoA) in runtime paths.
- Make all expensive transforms precomputed or table-driven where practical.

## 1. Global Data Layout Strategy

### 1.1 Storage Tiers

- REU (cold/warm data): full map package, texture pages, sprite atlases and variants, PVS blocks, large lookup banks, optional debug traces.
- Main RAM (hot data): active sector/edge windows, column clip buffers, draw descriptors, frame queues, DMA descriptors, audio state, game simulation state.
- VIC-visible memory: back/front bitmap, screen RAM, color RAM update staging.

### 1.2 Transfer Unit

- All REU assets are page-aligned in 256-byte units.
- Large assets are grouped into 1 KB "stream pages" for predictable DMA scheduling.
- Every streamable block has: `reu_base_page`, `byte_size`, `version_tag`.

### 1.3 Runtime Endianness And Numeric Formats

- Endianness: little-endian for all serialized integers.
- Coordinates: signed 16.16 fixed.
- Angle space: unsigned 16-bit turn (`0..65535`).
- Heights: signed 12.4 fixed (map authoring), expanded to 16.16 in hot paths.
- Distances for culling/light buckets: unsigned 8.8 fixed or indexed buckets.

## 2. Map Package Format

Map data is authored offline, then compiled into a `MAPBIN` container with section directory and page alignment.

### 2.1 Container Header

```c
typedef struct {
	char magic[6];          // "MAPBIN"
	uint8_t format_version; // Increment on incompatible layout changes
	uint8_t section_count;
	uint16_t map_id;
	uint16_t supersector_count;
	uint16_t sector_count;
	uint16_t linedef_count;
	uint16_t vertex_count;
	uint32_t directory_offset;
	uint16_t reserved;
} MapBinHeader;
```

Directory entry:

```c
typedef struct {
	uint8_t section_id;     // enum MapSectionId
	uint8_t flags;          // compressed, streamable, resident-hint
	uint16_t reserved;
	uint32_t reu_page_base; // page index, not byte address
	uint32_t byte_size;
	uint16_t aux;           // section-specific metadata
} MapSectionDir;
```

### 2.2 Map Sections

Required sections:

- `SEC_VERTICES`
- `SEC_LINEDEFS`
- `SEC_SIDEDEFS`
- `SEC_SECTORS`
- `SEC_PORTALS`
- `SEC_SUPERSECTOR`
- `SEC_PVS`
- `SEC_COLLISION_GRID`
- `SEC_THING_SPAWNS`
- `SEC_TEXTURE_REFS`
- `SEC_SOUND_REFS`

Optional sections:

- `SEC_SCRIPT_TRIGGERS`
- `SEC_LIGHT_ANIM`
- `SEC_RESERVED_GAMEPLAY`

### 2.3 Runtime-Oriented Sector And Linedef Layout

Runtime transform/projection loops should not walk linked structs. Sector and edge data is staged into SoA slices:

#### Sector SoA (active window in RAM)

```c
typedef struct {
	uint16_t count;
	uint16_t id[MAX_ACTIVE_SECTORS];
	int32_t floor_z[MAX_ACTIVE_SECTORS];      // 16.16
	int32_t ceil_z[MAX_ACTIVE_SECTORS];       // 16.16
	uint16_t first_linedef[MAX_ACTIVE_SECTORS];
	uint16_t linedef_count[MAX_ACTIVE_SECTORS];
	uint8_t light_band[MAX_ACTIVE_SECTORS];
	uint8_t material_group[MAX_ACTIVE_SECTORS];
	uint8_t floor_tex_page[MAX_ACTIVE_SECTORS];
	uint8_t ceil_tex_page[MAX_ACTIVE_SECTORS];
} SectorWindow;
```

#### Linedef SoA (active edge list in RAM)

```c
typedef struct {
	uint16_t count;
	int32_t x0[MAX_ACTIVE_EDGES]; // world 16.16
	int32_t y0[MAX_ACTIVE_EDGES];
	int32_t x1[MAX_ACTIVE_EDGES];
	int32_t y1[MAX_ACTIVE_EDGES];
	uint16_t front_sector[MAX_ACTIVE_EDGES];
	uint16_t back_sector[MAX_ACTIVE_EDGES];   // 0xFFFF for solid wall
	uint16_t tex_upper[MAX_ACTIVE_EDGES];
	uint16_t tex_mid[MAX_ACTIVE_EDGES];
	uint16_t tex_lower[MAX_ACTIVE_EDGES];
	uint8_t flags[MAX_ACTIVE_EDGES];          // portal, impassable, masked
	uint8_t preclip_class[MAX_ACTIVE_EDGES];  // coarse reject class
} EdgeWindow;
```

Why SoA here:

- Per-column loops consume only selected fields.
- Better linear memory access when projecting many edges.
- Easier partial DMA fill of just needed columns/attributes.

### 2.4 Portal And Traversal Data

Portal traversal relies on compact adjacency and screen-window propagation.

```c
typedef struct {
	uint16_t linedef_id;
	uint16_t from_sector;
	uint16_t to_sector;
	uint8_t min_opening_bucket; // quantized opening height
	uint8_t max_depth_bucket;
	uint8_t traversal_cost;
	uint8_t reserved;
} PortalEntry;
```

Each sector has a contiguous portal span: `portal_start[sector]`, `portal_count[sector]`.

### 2.5 Supersector And PVS

To avoid broad fan-out, sectors are grouped into supersectors (coarse regions).

```c
typedef struct {
	uint16_t first_sector;
	uint16_t sector_count;
	int16_t bbox_min_x, bbox_min_y; // map grid units, not 16.16
	int16_t bbox_max_x, bbox_max_y;
	uint32_t pvs_reu_page;          // bitset blocks in REU
	uint16_t pvs_byte_size;
	uint16_t neighbor_mask_word0;   // small fast-path adjacency mask
} SupersectorMeta;
```

PVS encoding:

- Bitset over supersector IDs.
- Optionally RLE-compressed for sparse maps.
- Decompressed into a tiny RAM bitset cache for current and predicted next supersector.

### 2.6 Collision And Actor Spawn Support

Renderer-aligned gameplay structures:

- Uniform collision grid (coarse cells) with cell-to-linedef spans.
- Spawn table sorted by supersector for streaming-friendly activation.

```c
typedef struct {
	int32_t x, y, z;          // 16.16
	uint16_t archetype_id;
	uint8_t angle8;           // coarse orientation for quick setup
	uint8_t flags;            // dormant, ambush, trigger-linked
	uint16_t initial_state;
} ThingSpawn;
```

## 3. Lookup Table Banks

Lookup tables are split into banks by update frequency and hotness.

### 3.1 Bank Types

- `LUT_HOT_RAM`: always resident, tiny, used in inner loops.
- `LUT_WARM_RAM`: frame-resident based on view bucket.
- `LUT_REU_STREAM`: large tables fetched by angle/depth/material demand.

### 3.2 Core Math LUTs

#### Trig LUT

- `sin[2048]`, `cos[2048]` in signed 1.15 fixed.
- Angle input `0..65535` maps to `0..2047` via top 11 bits.
- Optional 1-step interpolation uses low 5 angle bits only for near geometry.

#### Reciprocal LUT

- `rcp_z[1..Z_MAX_BUCKET]` in 0.16 or 4.12 fixed by consumer.
- Includes guard entries for near-plane clamp.
- Separate table for wall-height projection scale.

#### Tangent / FOV LUT

- Horizontal ray factors per column (`160` entries).
- Pre-scaled by projection plane distance.
- Additional half-column offsets for texture stepping bias correction.

### 3.3 Projection And Clip LUTs

- Column-to-ray index map: `col_ray_idx[160]`.
- Clip class LUT from camera-space signs and near-plane relation.
- Screen y quantization LUT from projected height buckets.

```c
typedef struct {
	int16_t ray_dx[160];
	int16_t ray_dy[160];
	uint8_t col_group[160]; // group columns for coarse stepping fallback
} ColumnRayLut;
```

### 3.4 Lighting And Dither LUTs

- `light_to_palette[LIGHT_BANDS][MATERIAL_GROUPS]`.
- `light_to_pattern[LIGHT_BANDS][PATTERN_IDS]` (ordered dither indices).
- Distance-based precision profile LUT: selects full/half/quarter sampling mode.

### 3.5 Multicolor Packing LUTs

Critical for commit speed:

- 2bpp texel quad -> VIC multicolor byte mapping.
- Pixel pair packing for aligned and half-shifted cases.
- Screen RAM nibble pair assembly table.
- Color RAM nibble merge table with dirty-mask assist.

### 3.6 Texture Step LUTs

For each depth bucket and scale mode:

- `u_step`, `v_step`, `v_start_bias`.
- Pre-quantized for fixed-point accumulation without division.

### 3.7 Sprite/Billboard LUTs

- Scale bucket table (world depth -> sprite variant index).
- Orientation quantization table (angle delta -> frame index).
- Billboard x-span LUT for width clipping and masked run decode.

## 4. Sprite And Billboard Asset Structures

VIC hardware sprites are not used as world entities. Scene actors are blitted from REU-managed sprite pages.

### 4.1 Sprite Catalog

```c
typedef struct {
	uint16_t sprite_id;
	uint8_t frame_count;
	uint8_t orientation_count; // e.g. 8 or 16 facings
	uint8_t scale_bucket_count;
	uint8_t flags;             // translucent, additive-like, shadow-only
	uint32_t frame_table_reu_page;
	uint16_t bbox_radius;      // 8.8 fixed world units
	uint16_t height_nominal;   // 8.8
} SpriteCatalogEntry;
```

Frame variant descriptor:

```c
typedef struct {
	uint16_t w_px;
	uint16_t h_px;
	int16_t pivot_x;
	int16_t pivot_y;
	uint16_t encoded_format;   // RLE column, mask+solid runs, raw tiles
	uint16_t opaque_ratio_q8;  // helps decide if worth early reject tests
	uint32_t pixel_data_reu_page;
	uint32_t mask_data_reu_page;
} SpriteVariant;
```

### 4.2 Column-Oriented Sprite Encoding

Preferred encoding for wall-compatible depth clip integration:

- Column run lists: `(y_start, y_len, src_offset)` entries.
- Optional skip-mask blocks per 8-pixel chunk.
- Variant-level x-column bounds for fast out-of-screen rejection.

Benefits:

- Natural fit for per-column occlusion buffer checks.
- Easy transparent run skipping.
- Predictable CPU cost with run-count caps.

### 4.3 Runtime Sprite Work Queues

`SpriteCandidate` (from gameplay update):

```c
typedef struct {
	uint16_t actor_id;
	int32_t rel_x, rel_y, rel_z; // camera-space 16.16 after transform
	uint16_t sprite_id;
	uint8_t state_frame;
	uint8_t flags;
} SpriteCandidate;
```

`SpriteDrawCmd` (post-cull, post-scale selection):

```c
typedef struct {
	uint16_t variant_id;
	int16_t screen_x0, screen_x1;
	int16_t screen_y0, screen_y1;
	uint8_t depth_bucket;
	uint8_t light_band;
	uint16_t mask_ref;
	uint32_t pixel_reu_page;
} SpriteDrawCmd;
```

Queue rules:

- Hard cap per frame: `MAX_SPRITE_CMDS`.
- Overflow policy: deterministic drop by priority class and depth.
- Optional temporal decimation flag for low-priority effects.

## 5. Frame-Time Working Sets In RAM

The engine should allocate fixed-capacity arrays, never frame-heap allocations.

### 5.1 Renderer Scratch

- Column clip top/bottom arrays for 160 columns.
- Wall descriptor SoA arrays.
- Floor/ceiling span records.
- Tile dirty masks for bitmap/screen/color outputs.

```c
typedef struct {
	uint8_t col_top[160];
	uint8_t col_bottom[160];
	uint16_t wall_count;
	uint16_t span_count;
	uint16_t sprite_count;
} FrameVisibilityState;
```

### 5.2 Stream Control

- Pending DMA request ring buffer.
- Resident page table (map pages, texture pages, sprite pages, LUT pages).
- Last-used frame index for replacement policy.

```c
typedef struct {
	uint32_t reu_page;
	uint16_t ram_addr;
	uint16_t byte_size;
	uint8_t priority;
	uint8_t type; // map, tex, sprite, lut
} DmaRequest;
```

Policy:

- Deterministic replacement with bias to currently visible and predicted-near-visible sectors.
- Separate tiny reserve for audio-critical buffers so renderer cannot starve music playback.

## 6. Section-Level Optimization Rules

### 6.1 Map Rules

- Keep per-sector linedef lists contiguous.
- Keep portal lists contiguous and pre-sorted by likely screen contribution.
- Encode frequently tested flags into bitfields packed for single-byte branch tests.

### 6.2 LUT Rules

- Tables used in inner loops must fit in a known RAM window.
- Angle/depth quantization sizes should be powers of two for cheap masking/shifts.
- Avoid runtime normalization if an authoring/export step can pre-normalize.

### 6.3 Sprite Rules

- Store pre-sized variants instead of runtime scaling.
- Prefer column-RLE encodings with bounded run counts.
- Maintain orientation and scale indirection tables in RAM; stream only pixel/mask payloads.

## 7. Build Pipeline Outputs (Offline)

The data compiler should emit:

- `map.bin` with section directory and validation metadata.
- `lut.bin` grouped by hot/warm/stream banks.
- `sprite.bin` with catalog and variant pages.
- `stream_plan.bin` containing prefetch hints by supersector transition.
- `validation_report.txt` with cap checks (`MAX_ACTIVE_SECTORS`, `MAX_ACTIVE_EDGES`, sprite cap, worst-case DMA volume).

The compiler should emit diagnostics if worst-case estimates exceed frame budgets under configured quality tiers.

