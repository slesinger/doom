# Doom C64U Pipeline Model (PipeScript)

> **What this document is.** A high-level, deliberately non-runnable model of
> the *target* frame loop, written in a made-up language (`PipeScript`) so that
> stage boundaries, queue capacities and overflow policies can be stated without
> committing to 6510 detail.
>
> For the **implemented** pipeline — the same journey in real assembly, with
> cycle counts and a worked frame — see **[`pipeline.md`](pipeline.md)**.
> §10 below maps every stage here onto the routine that implements it (or
> records that nothing does).

This file defines a high-level conceptual pipeline using a made-up language named `PipeScript`.
It is intentionally non-runnable and focuses on the frame loop and stage boundaries.

Goals:

- Deterministic frame progression.
- Clear flow from player input to final render commit.
- Explicit wall filtering and bounded rendering work.

## 1. PipeScript Core Concepts

- `stage`: Named pipeline stage with defined inputs and outputs.
- `state`: Persistent game/runtime data.
- `frame`: Per-frame scratch data.
- `queue`: Bounded list with deterministic overflow policy.
- `table`: Precomputed lookup data.
- `budget`: Hard cap for work in current frame.

## 2. Global State (Conceptual)

```pipescript
state Engine {
	tick                : u64
	dt_fixed            : fx16_16

	player              : PlayerState
	camera              : CameraState
	world               : WorldState

	resident_pages      : PageResidency
	stream_scheduler    : StreamScheduler

	audio               : AudioState
	quality             : QualityState

	luts                : LookupSet
}

state Frame {
	visible_sectors     : queue<SectorId>(MAX_ACTIVE_SECTORS)
	candidate_walls     : queue<WallId>(MAX_ACTIVE_EDGES)
	filtered_walls      : queue<WallWork>(MAX_FILTERED_WALLS)
	sprite_candidates   : queue<SpriteCandidate>(MAX_SPRITE_CANDIDATES)
	draw_cmds           : queue<DrawCmd>(MAX_DRAW_CMDS)

	col_clip_top[160]   : u8
	col_clip_bottom[160]: u8

	stats               : FrameStats
}
```

## 3. Stage Pipeline Definition

```pipescript
pipeline DoomFrame(engine: Engine) -> Engine {
	frame := Frame.reset()

	stage PollInput
	stage SimulatePlayer
	stage ResolveCamera
	stage PredictStreaming
	stage BuildVisibleSectorSet
	stage CollectCandidateWalls
	stage FilterWalls
	stage ProjectWallsToColumns
	stage BuildSpriteCandidates
	stage CullAndSortSprites
	stage BuildDrawCommands
	stage RasterizeWallsAndSprites
	stage CommitBackbuffer
	stage UpdateAudio
	stage EndFrame

	return engine
}
```

## 4. High-Level Loop

```pipescript
loop GameLoop while engine.world.running {
	frame_start := clock.now()

	engine = DoomFrame(engine)

	frame_cost := clock.now() - frame_start
	if frame_cost > BUDGET_25_FPS {
		engine.quality = quality.degrade_step(engine.quality)
	} else {
		engine.quality = quality.recover_step(engine.quality)
	}
}
```

## 5. Stage Logic

### 5.1 Input And Movement

```pipescript
stage PollInput {
	input := devices.read_controller()
	engine.player.intent.move = input.axis_xy
	engine.player.intent.turn = input.axis_turn
	engine.player.intent.actions = input.buttons
}

stage SimulatePlayer {
	desired_vel := movement.intent_to_velocity(
		engine.player.intent,
		engine.player.move_params,
		engine.dt_fixed
	)

	constrained_vel := collision.slide_move(
		desired_vel,
		engine.player.position,
		engine.world.collision_grid
	)

	engine.player.position += constrained_vel
	engine.player.angle = angle.wrap_u16(engine.player.angle + engine.player.intent.turn)
}
```

### 5.2 Camera And Streaming

```pipescript
stage ResolveCamera {
	engine.camera.position = camera.from_player(engine.player.position)
	engine.camera.angle = engine.player.angle
	engine.camera.sin = engine.luts.sin[engine.camera.angle >> 5]
	engine.camera.cos = engine.luts.cos[engine.camera.angle >> 5]
	engine.camera.sector = sectors.find_current(engine.player.position, engine.camera.sector)
}

stage PredictStreaming {
	hints := stream.predict_pages(
		engine.camera.sector,
		engine.player.velocity,
		engine.world.supersector_graph
	)
	engine.stream_scheduler.enqueue(hints)
	dma.execute_budgeted(engine.stream_scheduler, DMA_BYTES_PER_FRAME)
}
```

### 5.3 Visibility And Wall Filtering

```pipescript
stage BuildVisibleSectorSet {
	frame.visible_sectors.push(engine.camera.sector)

	traverse.portal_bfs(
		start_sector = engine.camera.sector,
		portal_window = screen.full_window(),
		pvs = engine.world.pvs,
		budget = MAX_ACTIVE_SECTORS,
		out = frame.visible_sectors
	)
}

stage CollectCandidateWalls {
	for sector_id in frame.visible_sectors {
		walls := world.sector_walls(sector_id)
		frame.candidate_walls.push_all_bounded(walls)
	}
}

stage FilterWalls {
	for wall_id in frame.candidate_walls {
		wall := world.wall(wall_id)

		if reject.backface(wall, engine.camera)         { continue }
		if reject.near_plane(wall, engine.camera)       { continue }
		if reject.horizontal_fov(wall, engine.camera)   { continue }
		if reject.too_small_on_screen(wall, engine.camera, engine.quality) { continue }

		work := wall.prepare_work(wall, engine.camera, engine.luts)
		frame.filtered_walls.push_bounded(work)
	}

	frame.filtered_walls = sort.front_to_back(frame.filtered_walls)
}
```

### 5.4 Projection, Sprites, And Draw Command Build

```pipescript
stage ProjectWallsToColumns {
	clip.reset(frame.col_clip_top, frame.col_clip_bottom)

	for wall_work in frame.filtered_walls {
		cols := project.wall_to_columns(wall_work, engine.luts)
		occluded_cols := clip.apply_and_reduce(cols, frame.col_clip_top, frame.col_clip_bottom)

		if occluded_cols.empty() { continue }

		cmd := draw.wall_cmd_from_columns(occluded_cols, wall_work, engine.quality)
		frame.draw_cmds.push_bounded(cmd)
	}
}

stage BuildSpriteCandidates {
	actors := world.actors_in_sectors(frame.visible_sectors)
	for actor in actors {
		sc := sprite.to_camera_space(actor, engine.camera)
		frame.sprite_candidates.push_bounded(sc)
	}
}

stage CullAndSortSprites {
	kept := queue<SpriteDrawCmd>(MAX_SPRITE_CMDS)

	for sc in frame.sprite_candidates {
		if reject.behind_camera(sc) { continue }
		if reject.outside_screen_x(sc, engine.luts) { continue }
		if reject.fully_occluded_by_clip(sc, frame.col_clip_top, frame.col_clip_bottom) { continue }

		kept.push_bounded(sprite.select_variant(sc, engine.world.sprite_catalog))
	}

	kept = sort.back_to_front(kept)
	frame.draw_cmds.push_all_bounded(kept)
}
```

### 5.5 Raster And Frame Finalization

```pipescript
stage BuildDrawCommands {
	frame.draw_cmds = scheduler.pack_by_material_page(frame.draw_cmds)
	frame.draw_cmds = scheduler.enforce_budget(frame.draw_cmds, MAX_DRAW_CMDS, DROP_FARTHEST_FIRST)
}

stage RasterizeWallsAndSprites {
	raster.begin_backbuffer()

	for cmd in frame.draw_cmds {
		match cmd.kind {
			WALL   => raster.draw_wall_columns(cmd, engine.luts, engine.quality)
			SPRITE => raster.draw_sprite_columns(cmd, engine.luts, engine.quality)
		}
	}

	raster.draw_deferred_floors_and_ceilings(engine.quality)
}

stage CommitBackbuffer {
	dirty := raster.build_dirty_tiles()
	commit.bitmap_and_screen(dirty)
	commit.color_ram(dirty)
	display.flip()
}

stage UpdateAudio {
	audio.mix_and_push(engine.audio, AUDIO_BUDGET_CYCLES)
}

stage EndFrame {
	engine.tick += 1
	frame.stats.wall_in   = frame.candidate_walls.count
	frame.stats.wall_out  = frame.filtered_walls.count
	frame.stats.draw_cmds = frame.draw_cmds.count
	profiler.record(frame.stats)
}
```

## 6. Determinism And Safety Rules

```pipescript
rule R1: Every queue has a hard maximum capacity.
rule R2: Overflow policy must be deterministic (stable priority then depth).
rule R3: No dynamic allocation during GameLoop.
rule R4: Any stage can downgrade quality, no stage can exceed frame budget.
rule R5: Streaming and rendering budgets are independent to protect audio update time.
```

## 7. Minimal Readable Summary

```text
input -> player movement -> camera update -> sector visibility -> wall collection
-> wall filtering -> wall projection + column clipping -> sprite cull/sort
-> draw command packing -> rasterize -> commit backbuffer -> audio -> next frame
```

## 8. Stage-To-Implementation Map

Where each stage above actually lives in `src/`, as of Milestone 1.
`pipeline.md` §14 carries the same table with the reasoning behind each gap.

| PipeScript stage | Implemented in | State |
|---|---|---|
| `PollInput` | `input.asm` → `readInput` | complete |
| `SimulatePlayer` | `input.asm` → `movePlayer`, `checkSector` | integer coords, undo-based collision, no `dt` |
| `ResolveCamera` | `render/walls.asm` → `renderFrame` (inline) | complete |
| `PredictStreaming` | — | not started (no REU streaming) |
| `BuildVisibleSectorSet` | `render/walls.asm` → `popLoop` portal stack | no PVS, no supersectors; `PSTKMAX = 12` |
| `CollectCandidateWalls` | `render/walls.asm` → `renderSector` wall loop | complete |
| `FilterWalls` | `render/walls.asm` → `doWall` (near plane, backface, window clamp) | complete |
| `sort.front_to_back` | **not needed** — convex sectors project to disjoint column ranges | by construction |
| `ProjectWallsToColumns` | `render/walls.asm` → `lineSetup` + `!colloop` | complete |
| `BuildSpriteCandidates` | — | not started |
| `CullAndSortSprites` | — | not started |
| `BuildDrawCommands` | **fused** — spans emitted directly from the column loop | no draw-command queue exists |
| `RasterizeWallsAndSprites` | `math.asm` → `spanFill` | flat-shaded, no textures, no sprites |
| `draw_deferred_floors_and_ceilings` | drawn inline instead | causes ~20% overdraw through portals |
| `CommitBackbuffer` | `render/chunky2mc.asm` → `convert`, `flip` | complete; no dirty-tile masks |
| `UpdateAudio` | — | not started |
| `EndFrame` / `quality.degrade_step` | — | no profiling, no quality scaling |

Two structural divergences are choices rather than omissions:

- **No draw-command queue.** §5.4-5.5 build `draw_cmds` and rasterize them in a
  later pass; the implementation writes spans directly from the column loop.
  That saves a queue, a packing pass and the RAM for both — but it forecloses
  `scheduler.pack_by_material_page` and the deferred floor/ceiling pass. This is
  the decision to revisit when textures make material-page locality matter.
- **Every cap is hard, none are adaptive.** `PSTKMAX`, 160 columns and 176 rows
  are compile-time limits with deterministic overflow (satisfying rules R1-R3),
  but rule R4's quality downgrade needs a per-frame cycle counter the engine
  does not yet have.
