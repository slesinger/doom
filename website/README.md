# DOOM C64U website

Static, single-file SPA. No build step, no server, no external requests —
just open `index.html` in a browser, or host it anywhere as a static file
(this is meant to end up served from `hondani.com`).

```
website/
  index.html   ← the whole site (self-contained: CSS + JS inline, no CDN)
  screenshots/ ← real screenshots go here once shot (see below) — create it
  README.md    ← this file
```

## Editing

Everything lives in `index.html`, split into tab "panels" (`#panel-overview`,
`#panel-tech`, `#panel-performance`, `#panel-roadmap`, `#panel-faq`,
`#panel-community`). Tabs are pure client-side JS — no routing, no build.

## Screenshots to shoot

Every screenshot slot in the page is a dashed placeholder box labeled
**"TO FILL"** with a caption describing exactly what to capture. Honza is
capturing these with [HDN Shell](https://hdn.sh/) — Hondani's other C64
Ultimate project — off real hardware; the Overview screenshot grid already
credits it, keep that credit if you change the shots around.

**Where to put files:** create `website/screenshots/` and drop images in
flat, e.g. `screenshots/hero.png`, `screenshots/corridor.png`. Reference them
with a path relative to `index.html`, e.g. `src="screenshots/hero.png"`.

**How to swap a placeholder for a real image:** replace the *entire*
contents of the `.shot` div (the `.shot-tag`, `.shot-fill`, and `.shot-inner`
children) with a single `<img class="shot-img" src="screenshots/....png"
alt="...">`. Keep the outer `.shot` div and its aspect-ratio class
(`shot-16x9`, `shot-4x3`, `shot-21x9`, `shot-1x1`) so the layout doesn't
shift — `.shot-img` fills the box with `object-fit:cover`, so it'll crop to
fit if the source aspect ratio is slightly off. Don't leave the placeholder
markup in place alongside the `<img>`; they're not meant to coexist.

**Click-to-zoom:** any `<img class="shot-img">` is automatically wired up to
a fullscreen lightbox (click to enlarge, click again or Esc to close) — no
per-image setup needed, it's delegated in the page's own `<script>`. This is
what makes small thumbnails in the grid layouts fine to browse at a glance
while still letting anyone see the full-resolution capture.

**What resolution to capture at, and why 320×200 isn't enough:**

- The engine's native render is only 160×176 chunky pixels (~320×176 once
  VIC-II multicolor mode is accounted for) — genuinely tiny by modern
  standards, so a 1:1 capture will look like a postage stamp on a modern
  screen no matter how it's placed in the page.
- **From real hardware (preferred):** capture via whatever HDMI-out capture
  path you're using (capture card, OBS, phone camera on the TV, etc.) at
  *its* native output resolution — don't downscale to match the C64's
  resolution. The U64's HDMI output is already upscaled from the low native
  image, so a 1080p-ish capture crop still reads as crisp, not blurry, once
  it's the thing actually being displayed. Aim for at least ~1280px on the
  long edge after cropping to the game view; more is fine, the lightbox and
  `object-fit:cover` thumbnails both scale down gracefully.
- **From the emulator, if you have no HDMI capture:** VICE's own screenshot
  (`make shot` → `build/shot.png`) is 384×272 — also too small to publish
  as-is. Scale it up with **nearest-neighbor** (not bilinear/bicubic)
  resampling to avoid blur — e.g. ImageMagick
  `convert build/shot.png -filter point -resize 400% out.png`, or
  Photoshop/GIMP "None"/"nearest neighbor" interpolation — landing around
  1280–1600px on the long edge. This keeps the blocky pixel-art look
  intentional instead of turning it to mush.
- Either way: crop out the emulator/VICE window chrome or capture-tool UI
  first, and crop tight enough that the HUD/weapon-view region called out in
  each shot's caption is actually legible at thumbnail size.

Shot list, in the order they appear on the page:

1. **Hero shot** (Overview, 21:9) — widescreen crop from real hardware,
   E1M1, textured walls, a corridor opening into a lit room, weapon view +
   HUD visible at the bottom. This is the first thing anyone sees — use the
   best "this shouldn't run on a C64" angle you have.
2. **Corridor / texture variety** (Overview, 4:3) — a long view showing 2–3
   different wall textures in frame, so it's clear it's not one tile
   repeated everywhere.
3. **Door / moving sector** (Overview, 4:3) — caught mid-transition, proof
   the level isn't a static diorama.
4. **Prop / barrel sprite** (Overview, 4:3) — a sprite close-up in-scene,
   reading clearly against the wall texture behind it.
5. **HUD close-up** (Overview, 4:3) — tight crop on the health/armor/ammo
   strip, sharp enough to read the digits.
6. **Video walkthrough** (Community, 1:1 placeholder → replace with a
   YouTube embed) — continuous real-time E1M1 walkthrough on real hardware
   (not the emulator), HUD and weapon view visible. Consider a short
   side-by-side with the `make u64-fps` terminal output as proof of the
   measured frame rate. 2–4 minutes is plenty.
7. **Proof shot** (Community, 16:9) — a clean terminal screenshot of a real
   `make u64-fps` run: the fps line, the compute-time line, and the "100% on
   deadline" histogram line. This is the receipt for every number quoted on
   the site.

## Performance numbers

Pulled from `README.md`, `IMPLEMENTATION_PLAN.md` and hardware-measured
`make u64-fps` runs. Last checked 2026-08-13 — re-verify against
`IMPLEMENTATION_PLAN.md` before publishing if anything's landed since:

- **Earlier baseline**: 25.05 fps, 502/502 frames on deadline, 37.6 ms
  compute against a 39.90 ms deadline (flat-shaded, no textures/sprites).
- **Current**: 16.6 fps locked, 59.85 ms deadline, textured walls / doors /
  moving sectors / jump / walk bob / sprites / weapon view / HUD all
  shipped, compute measured at ~46–48 ms.

## WAD / assets

`assets/DOOM1.WAD` is never committed (see `assets/DOOM1.WAD.README` in the
repo root) — nothing on this site should imply it ships with the repo.
Site copy says "shareware/demo WAD or a licensed copy," not "licensed copy"
alone — keep it that way; it's both more accurate and lower-risk.

## Legal

The legal/trademark notice in the Community tab is required content per the
project's promotion plan (`../PROMOTION.md` §2.2, §8) — don't ship without
it if this goes public. The site targets the official Commodore C64 Ultimate
(2025) only — it does not run on the third-party "1541 Ultimate" — don't
reintroduce that attribution.
