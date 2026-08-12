# Doom C64U — build system
#
# Targets:
#   make            build build/doom.prg
#   make run        run in VICE (128K REU preloaded with build/assets.reu)
#   make shot       headless VICE run, screenshot to build/shot.png
#   make check      the regression gate: build + shot content + live-RAM diff
#   make debug      live-RAM vs PRG diff under the VICE binary monitor
#   make walktest   drive the player along a wall and into a corner, and
#                   judge the path against E1M1's own linedefs
#   make doortest   open a door, hold it, close it -- judged against SECTAB
#   make stats      emulated ms/frame + renderer workload counters
#   make profile    per-frame call counts for the hot routines
#   make assets     DOOM1.WAD -> build/assets.reu, plus build/testmap.reu
#   make music      assets/DooM_Medley.sid -> build/music.bin (block 5)
#   make u64-config apply the required turbo settings to the Ultimate
#   make run-u64    push PRG to the Ultimate over the network and run it
#   make u64-fps    run on the Ultimate and measure the real frame rate
#   make u64-map    run on the Ultimate and verify the REU map image landed
#   make reubench   measure REU DMA throughput on the Ultimate
#   make audiotest  the two audio-feasibility probes (sidtest + irqtest)
#   make intro      build/intro.prg + build/intro.reu -- the title screen
#   make run-intro  run the title screen in VICE (picture only -- see
#                   src/intro/ultaudio.asm for why VICE has no sound here)
#   make run-intro-u64  push the title screen to the Ultimate and run it,
#                   with sound
#   make clean

# KickAssembler is only distributed from theweb.dk; keep the location
# overridable so CI / containers can supply their own copy.
KICKASS_JAR ?= /home/honza/projects/c64/pc-tools/kickass/KickAss.jar
KICKASS   := java -jar $(KICKASS_JAR)
VICE      ?= x64sc
# set to "xvfb-run -a" on a headless machine
VICEWRAP  ?=
PYTHON    := python3

# The C64 Ultimate on the LAN. It does not advertise itself over mDNS, so
# this is an address, not a name; override like: make run-u64 U64_HOST=1.2.3.4
# To find it again: curl -s -m2 http://<ip>/v1/info on each host in the subnet
# — the Ultimate is the one that answers with a JSON "product" field.
U64_HOST  ?= 192.168.1.65

SRC       := $(wildcard src/*.asm src/render/*.asm)
PRG       := build/doom.prg
# Overridable so the whole engine can be run against the 3-sector test map,
# which goes through the same converter and the same BSP builder:
#     make run   REUIMG=build/testmap.reu
#     make shot  REUIMG=build/testmap.reu
# That is the input to bring a traversal change up on before E1M1's 732 segs
# are involved -- it separates "the converter is wrong" from "the walk is
# wrong", which is the distinction that cost the last debugging session six
# hypotheses (IMPLEMENTATION_PLAN.md §7).
REUIMG    ?= build/assets.reu
TESTREU   := build/testmap.reu
WAD       := assets/DOOM1.WAD

# VICE: REU with the map image attached read-only.
#
# ORDER MATTERS: REUOPTS must come *after* VICEOPTS on every command line,
# because VICEOPTS leads with `-default`, and `-default` resets every setting
# to its factory value -- including the REU enable. With `-reu -default` the
# emulator boots with no REU at all and says nothing about it: $DF00-$DF0A read
# back as $00, every DMA is a silent no-op, and `-reuimage` is ignored. That is
# how it was written until 2026-08-09, so no VICE run before then had an REU.
# -reusize must match the padding wad2reu.py applies (REU_IMAGE_SIZE): VICE
# refuses an image that is not exactly the emulated REU size, and boots with a
# zeroed REU when it does. +reuimagerw keeps VICE from writing the image back
# on exit, which would otherwise stamp reuProbe's signature into a build artifact.
# -reusize must be >= the image wad2reu.py writes (REU_IMAGE_SIZE, now 512 KB
# to hold the music stream): VICE refuses an image larger than the emulated
# REU -- "Reading REU image ... failed" -- and then fails open into a BASIC
# READY screen, which looks like a hung engine and is not one.
REUOPTS    = -reu -reusize 512 +reuimagerw -reuimage $(REUIMG)
# +confirmexit is not a VICE option (VICE bails out); it is +confirmonexit.
# -autostartprgmode 1 injects the PRG directly, so no 1541 drive ROMs are
# needed. +sound keeps a missing audio device from killing a headless run.
# -default ignores this machine's saved vicerc: a vicerc left behind by some
# other VICE project (e.g. a cartridge or drive ROM override) can silently
# break -autostart, which fails open into a blank BASIC READY screen that
# looks a lot like -- but is not -- our own black-screen bug. shot/debug
# must be hermetic against whatever else has run x64sc on this machine.
VICEOPTS   = -default +confirmonexit -autostartprgmode 1 +sound

.PHONY: all run shot check debug stats profile framehash walktest doortest assets reubench run-u64 u64-config \
        u64-fps u64-map sidtest irqtest audiotest music setup clean \
        intro run-intro shot-intro run-intro-u64 intro-config

# `setup` is defined first for readability but must not be the default goal:
# a bare `make` has to build, as the README says it does.
.DEFAULT_GOAL := all

setup:
	sh tools/setup-dev-env.sh

all: $(PRG)

$(PRG): $(SRC)
	$(KICKASS) src/main.asm -odir build -o $(PRG) -showmem \
	    -symbolfile -vicesymbols

run: $(PRG) $(REUIMG)
	$(VICEWRAP) $(VICE) $(VICEOPTS) $(REUOPTS) -autostart $(PRG)

# Headless-ish automated check: run warp for a while, dump a screenshot, exit.
#
# x64sc exits non-zero when -limitcycles stops it, which is the *expected* end
# of this run -- so its status says nothing about success. Ignore it and judge
# the run by its artifact instead: the PNG must exist and be newer than the
# PRG. `make check` then judges the PNG's content.
SHOT_CYCLES ?= 50000000
SHOT        := build/shot.png
shot: $(PRG) $(REUIMG)
	rm -f $(SHOT)
	-$(VICEWRAP) $(VICE) $(VICEOPTS) $(REUOPTS) -warp \
	    -limitcycles $(SHOT_CYCLES) -exitscreenshot $(SHOT) \
	    -autostart $(PRG)
	@test -s $(SHOT) || { echo "shot: VICE wrote no $(SHOT)"; exit 1; }
	@echo "shot: wrote $(SHOT)"

# The regression gate. Three independent assertions, cheapest first:
#   build   the .errorif segment guards in main.asm hold
#   shot    VICE reaches a frame and the viewport has content (tools/checkshot.py)
#   debug   no write lands outside the engine's own buffers (tools/vicedbg)
# `shot` and `debug` cover different failures: debug is blind to a correct-but-
# black frame, checkshot is blind to a stray write that has not yet corrupted
# anything visible. Green means both.
MIN_COVERAGE ?= 0.30
check: $(PRG)
	@echo "== check 1/3: build"
	@$(MAKE) --no-print-directory $(PRG)
	@echo "== check 2/3: screenshot content"
	@$(MAKE) --no-print-directory shot
	$(PYTHON) tools/checkshot.py $(SHOT) --min-coverage $(MIN_COVERAGE)
	@echo "== check 3/3: live-RAM diff"
	@$(MAKE) --no-print-directory debug
	@echo "== check: all green"

# The REU DMA throughput benchmark: a standalone PRG that leaves its results
# in C64 RAM, and a host tool that DMA-reads them back and does the arithmetic.
# Answers whether DMA speed scales with the CPU turbo clock. (It does not.)
# The REU image uploader. Its own PRG, run before doom.prg: the Ultimate's REU
# Preload does not deliver the image (see the header of src/reuload.asm), so
# the host DMAs it into C64 RAM and this stub stashes it into the REU.
RELPRG := build/reuload.prg
$(RELPRG): src/reuload.asm src/reu.asm src/defs.asm
	$(KICKASS) src/reuload.asm -odir build -o $(RELPRG) -showmem -vicesymbols

BENCH := build/reubench.prg
$(BENCH): src/reubench.asm src/reu.asm src/defs.asm
	$(KICKASS) src/reubench.asm -odir build -o $(BENCH) -showmem -vicesymbols

reubench: $(BENCH) u64-config
	$(PYTHON) tools/reubench.py $(U64_HOST) $(BENCH)

# The two audio-feasibility probes. Neither touches the engine; both exist to
# answer a question that would otherwise be answered by a player that half
# works. See the headers of src/sidtest.asm and src/irqtest.asm.
#
#   sidtest  do SID register writes survive a 64 MHz CPU, including a
#            25-register burst written back to back?
#   irqtest  can an interrupt be taken and returned across the $34/$35
#            banking windows, and what does one cost?
#
# Both depend on u64-config for the same reason everything else does: without
# "C64U Turbo Registers" the machine ignores $d031 and the 64 MHz pass is a
# 1 MHz pass that says it is not.
SIDTEST := build/sidtest.prg
$(SIDTEST): src/sidtest.asm src/defs.asm
	$(KICKASS) src/sidtest.asm -odir build -o $(SIDTEST) -showmem -vicesymbols

IRQTEST := build/irqtest.prg
$(IRQTEST): src/irqtest.asm src/defs.asm
	$(KICKASS) src/irqtest.asm -odir build -o $(IRQTEST) -showmem -vicesymbols

sidtest: $(SIDTEST) u64-config
	$(PYTHON) tools/sidtest.py $(U64_HOST) $(SIDTEST)

irqtest: $(IRQTEST) u64-config
	$(PYTHON) tools/irqtest.py $(U64_HOST) $(IRQTEST)

audiotest: sidtest irqtest

# The title screen. Its own source directory (src/intro/), its own PRG and
# its own REU image -- it shares no memory map and no build artifact with
# doom.prg, and is pushed to hardware separately (see run-intro-u64). See
# the header of src/intro/intro.asm.
#
# build/intro-audio.asm and build/intro.reu come out of the same tool run
# (the .asm records how many bytes of PCM the .reu actually holds), so one
# recipe with two targets, the same shape as $(TESTREU) below.
INTROSRC   := $(wildcard src/intro/*.asm)
INTROPRG   := build/intro.prg
INTROREU   := build/intro.reu
INTROASM   := build/intro-audio.asm
KLA        := assets/doom-title.kla
INTROMP3   := assets/04 - Intermission From Doom.mp3
# The asset ships with spaces in its name, which Make's prerequisite lists
# cannot carry unescaped (quoting a prerequisite does nothing -- Make splits
# on whitespace regardless). $(space) is the standard GNU Make workaround:
# a variable whose value *is* one space, substituted for a backslash-space
# only in the one context (the prerequisite list) that needs it escaped.
empty      :=
space      := $(empty) $(empty)
INTROMP3_ESC := $(subst $(space),\ ,$(INTROMP3))

$(INTROPRG): $(INTROSRC) $(KLA) $(INTROASM)
	$(KICKASS) src/intro/intro.asm -odir build -o $(INTROPRG) -libdir build \
	    -showmem -symbolfile -vicesymbols

$(INTROREU) $(INTROASM) &: tools/mp3topcm.py $(INTROMP3_ESC)
	$(PYTHON) tools/mp3topcm.py "$(INTROMP3)" -o $(INTROREU) --asm $(INTROASM)

intro: $(INTROPRG) $(INTROREU)

# 4096 = 4 MB, and it must equal REU_SIZE in tools/mp3topcm.py: VICE refuses
# an -reuimage whose size is not exactly -reusize (docs/reu-format.md §9.1).
# The Ultimate's own REU Size is a separate setting and stays at 16 MB.
INTROREUOPTS = -reu -reusize 4096 +reuimagerw -reuimage $(INTROREU)

run-intro: $(INTROPRG) $(INTROREU)
	$(VICEWRAP) $(VICE) $(VICEOPTS) $(INTROREUOPTS) -autostart $(INTROPRG)

SHOT_INTRO := build/shot-intro.png
shot-intro: $(INTROPRG) $(INTROREU)
	rm -f $(SHOT_INTRO)
	-$(VICEWRAP) $(VICE) $(VICEOPTS) $(INTROREUOPTS) -warp \
	    -limitcycles $(SHOT_CYCLES) -exitscreenshot $(SHOT_INTRO) \
	    -autostart $(INTROPRG)
	@test -s $(SHOT_INTRO) || { echo "shot-intro: VICE wrote no $(SHOT_INTRO)"; exit 1; }
	@echo "shot-intro: wrote $(SHOT_INTRO)"

# Two settings this needs that u64-config does not touch (that one is the
# engine's turbo profile) -- see tools/introconfig.py.
intro-config:
	$(PYTHON) tools/introconfig.py $(U64_HOST)

# No --reu here, unlike run-u64: the music image is loaded once from the
# Ultimate's own menu and stays in REU RAM across resets, so pushing 3.6 MB
# over the network on every run buys nothing. Load it by hand when it changes:
#
#     put build/intro.reu on the machine (FTP, or the SD/USB card), then
#     Ultimate menu -> C64 and Cartridge Settings -> REU Preload Image
#     -> /Usb0/intro.reu, and reset.
#
# The menu path works where the REST API's identical config write does not --
# see docs/reu-format.md §9.2. $(INTROREU) stays a prerequisite so a changed
# mp3 still rebuilds the image and reminds you to reload it.
run-intro-u64: $(INTROPRG) $(INTROREU) u64-config intro-config
	$(PYTHON) tools/u64push.py $(U64_HOST) $(INTROPRG)

# The map images. Both go through the same packers in wad2reu.py; the format
# they share is frozen in docs/reu-format.md.
#
# testmap.reu is the 3-sector map of src/testmap.asm run through a BSP builder
# in the tool. It exists so the BSP traversal can be brought up on geometry
# that is 16 segs and already hand-traced (pipeline.md §11) before E1M1's 732
# segs are involved -- i.e. so a garbled first frame can be blamed on the
# converter or on the traversal, but not on both at once.
assets: $(REUIMG) $(TESTREU)

# The music stream is built separately and cached, because it is the output of
# running the tune through a 6502 emulator in Python (tools/cpu6502.py) for its
# whole 7:22 -- seconds of work that depends on the .sid and on nothing the map
# packer knows. `make assets` embeds the result as block 5; see docs/reu-format.md
# §4.6 and src/music.asm for what the engine does with it.
#
# build/testmap.reu deliberately gets no music: it is the geometry bring-up
# image, and it doubles as the test that a silent image boots and renders
# rather than being rejected (musOK = 0 with musErr = 0).
MUSICSID  ?= assets/DooM_Medley.sid
MUSICBIN  := build/music.bin

$(MUSICBIN): tools/sidstream.py tools/cpu6502.py $(MUSICSID)
	$(PYTHON) tools/sidstream.py $(MUSICSID) -o $@

music: $(MUSICBIN)

build/assets.reu: tools/wad2reu.py $(WAD) $(MUSICBIN)
	$(PYTHON) tools/wad2reu.py $(WAD) --music $(MUSICBIN) -o $@

$(TESTREU): tools/wad2reu.py
	$(PYTHON) tools/wad2reu.py --map TEST -o $(TESTREU)

# Real hardware. u64-config must run before the PRG: the engine selects its
# CPU speed by writing $D031, and that register only exists when the machine's
# Turbo Control is "C64U Turbo Registers". In any other mode the write is
# ignored and the engine runs at 1 MHz with no indication that it is doing so.
u64-config:
	$(PYTHON) tools/u64config.py $(U64_HOST)

# The REU image is DMA'd in chunk by chunk through $(RELPRG) -- u64push.py's
# default --reu-mode, hence the prerequisite. The Ultimate's own REU Preload
# is the other route and cannot be driven from here: it fires on a reset from
# the machine's own menu or a power cycle, and on neither machine:reset nor
# the reset inside run_prg (docs/reu-format.md §9.2). `--reu-mode preload`
# uploads the file for that workflow but cannot complete it.
run-u64: $(PRG) $(REUIMG) $(RELPRG) u64-config
	$(PYTHON) tools/u64push.py $(U64_HOST) $(PRG) --reu $(REUIMG)

# Verify on real hardware that the REU image reached the machine, at both ends
# of the path: --verify-reu diffs the whole used region of REU RAM against the
# image (the streamed blocks included -- they are most of it), and --verify-map
# then checks what the running engine made of the three resident blocks.
#
# Both are needed. --verify-map alone passes on an image whose first 16 KB
# arrived and whose tail did not, because all three resident blocks live in
# that first 16 KB -- which is precisely the state that rendered garbage on
# 2026-08-11 while every check the tool had reported green.
u64-map: $(PRG) $(REUIMG) $(RELPRG) u64-config
	$(PYTHON) tools/u64push.py $(U64_HOST) $(PRG) --reu $(REUIMG) \
	    --verify-reu --verify-map

# Measure the real frame rate: run, then read the engine's frame counter
# twice over U64_FPS_SECONDS of wall clock.
U64_FPS_SECONDS ?= 10
u64-fps: $(PRG) $(REUIMG) $(RELPRG) u64-config
	$(PYTHON) tools/u64push.py $(U64_HOST) $(PRG) --fps $(U64_FPS_SECONDS) 
	# --reu $(REUIMG)

# Run under the binary monitor and diff live RAM against the PRG image; a clean
# run reports no writes outside the engine's own buffers. See tools/vicedbg.
#
# The emulator is started in the background and must be reaped afterwards:
# probe.py's own `quit` does not always land (a wedged CPU can leave the
# monitor unresponsive), and a leaked x64sc holds the make recipe's stdout
# open, which hangs any `make debug | ...` pipeline until it is killed by hand.
# So: log VICE's chatter to a file, and kill both the backgrounded PID and its
# children -- under VICEWRAP the PID is xvfb-run, which does not pass the kill
# on to the x64sc it spawned. (Matching on the command line instead would also
# match this recipe's own shell, whose argv contains the whole recipe text.)
#
# The monitor port is randomised per run, and that is not cosmetic. x64sc binds
# it without SO_REUSEADDR, so after a run the closed connection sits in
# TIME-WAIT on that port for ~60 s and the *next* `make debug` fails to bind --
# silently: VICE boots and runs normally, only without a monitor, and probe.py
# just sees connection-refused. Back-to-back runs (i.e. `make check` twice)
# failed about half the time from exactly this. Override MONPORT to pin it.
ifndef MONPORT
MONPORT := $(shell shuf -i 6520-6899 -n 1)
endif
VICELOG := build/debug.log
debug: $(PRG) $(REUIMG)
	@mkdir -p build
	$(VICEWRAP) $(VICE) $(VICEOPTS) $(REUOPTS) -warp \
	    -binarymonitor -binarymonitoraddress ip4://127.0.0.1:$(MONPORT) \
	    -autostart $(PRG) > $(VICELOG) 2>&1 & \
	vpid=$$!; \
	$(PYTHON) tools/vicedbg/probe.py diff $(PRG) $(MONPORT); rc=$$?; \
	pkill -P $$vpid 2>/dev/null; kill $$vpid 2>/dev/null; \
	exit $$rc

# The movement acceptance test: does the player slide along a wall instead of
# stopping dead on it, and does a run into an inside corner end up inside the
# map? Same backgrounded-VICE dance as `debug`, and the same randomised port for
# the same reason. tools/vicedbg/walktest.py drives the running engine over the
# monitor and judges the path it takes against E1M1's own linedefs.
walktest: $(PRG) $(REUIMG)
	@mkdir -p build
	$(VICEWRAP) $(VICE) $(VICEOPTS) $(REUOPTS) -warp \
	    -binarymonitor -binarymonitoraddress ip4://127.0.0.1:$(MONPORT) \
	    -autostart $(PRG) > $(VICELOG) 2>&1 & \
	vpid=$$!; \
	$(PYTHON) tools/vicedbg/walktest.py $(MONPORT); rc=$$?; \
	pkill -P $$vpid 2>/dev/null; kill $$vpid 2>/dev/null; \
	exit $$rc

# The doors acceptance test (§11), and the same dance again. It judges the
# engine against SECTAB rather than against a picture, which is the whole point
# of the phase: a door is two bytes of sector height and the renderer never
# learns what one is.
doortest: $(PRG) $(REUIMG)
	@mkdir -p build
	$(VICEWRAP) $(VICE) $(VICEOPTS) $(REUOPTS) -warp \
	    -binarymonitor -binarymonitoraddress ip4://127.0.0.1:$(MONPORT) \
	    -autostart $(PRG) > $(VICELOG) 2>&1 & \
	vpid=$$!; \
	$(PYTHON) tools/vicedbg/doortest.py $(MONPORT); rc=$$?; \
	pkill -P $$vpid 2>/dev/null; kill $$vpid 2>/dev/null; \
	exit $$rc

# The pixel-exact acceptance test. Hashes the renderer's own output buffer at
# a frame boundary instead of judging a screenshot: -limitcycles stops wherever
# it stops, which is mid-flip often enough that two runs of the same build
# differ by a few dozen pixels, while MATRIX at a frame boundary is exact.
#
#   make framehash              # -> sha256 of the frame
#
# An optimization is accepted when the digest is unchanged. That is the same
# standard as IMPLEMENTATION_PLAN.md §13/§15's "0 of 104448 pixels differ",
# with the capture jitter taken out of it.
framehash: $(PRG) $(REUIMG)
	@mkdir -p build
	$(VICEWRAP) $(VICE) $(VICEOPTS) $(REUOPTS) -warp \
	    -binarymonitor -binarymonitoraddress ip4://127.0.0.1:$(MONPORT) \
	    -autostart $(PRG) > $(VICELOG) 2>&1 & \
	vpid=$$!; \
	$(PYTHON) tools/vicedbg/framehash.py $(MONPORT); rc=$$?; \
	pkill -P $$vpid 2>/dev/null; kill $$vpid 2>/dev/null; \
	exit $$rc

# Frame time in the emulator, plus the renderer workload behind it. Uses the
# same backgrounded-VICE dance as `debug`, and the same randomised port for the
# same reason. STATSECS is emulated *and* wall-clock seconds under -warp, so a
# short sample still covers many frames; raise it if the frame count is small.
#
# The numbers this prints are 1 MHz numbers. That is not a limitation: the
# frame cost measured here is a cycle count, and the Ultimate's measured
# 56.9 ms/frame at 64 MHz matches VICE's 4.0 s at 1 MHz to within a few percent
# (IMPLEMENTATION_PLAN.md §12). REU DMA is the one cost that does not scale --
# it is 1 byte/us on both -- so a change that trades CPU work for DMA bytes
# looks better here than it will on hardware.
#
# THE MUSIC IS THE ONE THING THIS CANNOT MEASURE. Its tick rate is a CIA latch,
# i.e. fixed in real time, while a frame here lasts 2.3 emulated seconds instead
# of 39.9 ms -- so an emulated frame absorbs ~231 music ticks where the Ultimate
# absorbs 4. The +5.7% this reports for the player is about sixty times its cost
# on hardware. Use `make u64-fps` for that one. See docs/reu-format.md §4.6.
STATSECS ?= 20
stats: $(PRG) $(REUIMG)
	@mkdir -p build
	$(VICEWRAP) $(VICE) $(VICEOPTS) $(REUOPTS) -warp \
	    -binarymonitor -binarymonitoraddress ip4://127.0.0.1:$(MONPORT) \
	    -autostart $(PRG) > $(VICELOG) 2>&1 & \
	vpid=$$!; \
	$(PYTHON) tools/vicedbg/stats.py $(MONPORT) $(STATSECS); rc=$$?; \
	pkill -P $$vpid 2>/dev/null; kill $$vpid 2>/dev/null; \
	exit $$rc

# Where the frame actually goes. Sets a non-stopping exec checkpoint on each hot
# routine and reports VICE's own hit counters per frame, so it profiles the
# shipping build from outside and costs the engine nothing -- which matters,
# because instrument.asm's counters already fill TABLES_FREE to its last byte.
#
# This is what found the 9.4% in IMPLEMENTATION_PLAN.md §15: the frame was 35%
# multiply chain and 18% udiv, and 47% of every transformPoint turned out to be
# the bounding-sphere test rather than a seg endpoint.
#
# Frames are ~2.4 emulated seconds each under -warp, so PROFSECS wants to be
# long enough for a double-figure frame count before the per-frame averages
# mean much.
PROFSECS ?= 25
profile: $(PRG) $(REUIMG)
	@mkdir -p build
	$(VICEWRAP) $(VICE) $(VICEOPTS) $(REUOPTS) -warp \
	    -binarymonitor -binarymonitoraddress ip4://127.0.0.1:$(MONPORT) \
	    -autostart $(PRG) > $(VICELOG) 2>&1 & \
	vpid=$$!; \
	$(PYTHON) tools/vicedbg/profile.py $(MONPORT) $(PROFSECS); rc=$$?; \
	pkill -P $$vpid 2>/dev/null; kill $$vpid 2>/dev/null; \
	exit $$rc

clean:
	rm -f build/*.prg build/*.sym build/*.vs build/*.reu build/*.png build/debug.log build/intro-audio.asm
