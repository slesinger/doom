# Doom C64U — build system
#
# Targets:
#   make            build build/doom.prg
#   make run        run in VICE (128K REU preloaded with build/assets.reu)
#   make shot       headless VICE run, screenshot to build/shot.png
#   make check      the regression gate: build + shot content + live-RAM diff
#   make debug      live-RAM vs PRG diff under the VICE binary monitor
#   make stats      emulated ms/frame + renderer workload counters
#   make profile    per-frame call counts for the hot routines
#   make assets     DOOM1.WAD -> build/assets.reu, plus build/testmap.reu
#   make u64-config apply the required turbo settings to the Ultimate
#   make run-u64    push PRG to the Ultimate over the network and run it
#   make u64-fps    run on the Ultimate and measure the real frame rate
#   make u64-map    run on the Ultimate and verify the REU map image landed
#   make reubench   measure REU DMA throughput on the Ultimate
#   make audiotest  the two audio-feasibility probes (sidtest + irqtest)
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
REUOPTS    = -reu -reusize 128 +reuimagerw -reuimage $(REUIMG)
# +confirmexit is not a VICE option (VICE bails out); it is +confirmonexit.
# -autostartprgmode 1 injects the PRG directly, so no 1541 drive ROMs are
# needed. +sound keeps a missing audio device from killing a headless run.
# -default ignores this machine's saved vicerc: a vicerc left behind by some
# other VICE project (e.g. a cartridge or drive ROM override) can silently
# break -autostart, which fails open into a blank BASIC READY screen that
# looks a lot like -- but is not -- our own black-screen bug. shot/debug
# must be hermetic against whatever else has run x64sc on this machine.
VICEOPTS   = -default +confirmonexit -autostartprgmode 1 +sound

.PHONY: all run shot check debug stats profile assets reubench run-u64 u64-config \
        u64-fps u64-map sidtest irqtest audiotest setup clean

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

# The map images. Both go through the same packers in wad2reu.py; the format
# they share is frozen in docs/reu-format.md.
#
# testmap.reu is the 3-sector map of src/testmap.asm run through a BSP builder
# in the tool. It exists so the BSP traversal can be brought up on geometry
# that is 16 segs and already hand-traced (pipeline.md §11) before E1M1's 732
# segs are involved -- i.e. so a garbled first frame can be blamed on the
# converter or on the traversal, but not on both at once.
assets: $(REUIMG) $(TESTREU)

build/assets.reu: tools/wad2reu.py $(WAD)
	$(PYTHON) tools/wad2reu.py $(WAD) -o $@

$(TESTREU): tools/wad2reu.py
	$(PYTHON) tools/wad2reu.py --map TEST -o $(TESTREU)

# Real hardware. u64-config must run before the PRG: the engine selects its
# CPU speed by writing $D031, and that register only exists when the machine's
# Turbo Control is "C64U Turbo Registers". In any other mode the write is
# ignored and the engine runs at 1 MHz with no indication that it is doing so.
u64-config:
	$(PYTHON) tools/u64config.py $(U64_HOST)

run-u64: $(PRG) $(REUIMG) $(RELPRG) u64-config
	$(PYTHON) tools/u64push.py $(U64_HOST) $(PRG) --reu $(REUIMG)

# Verify on real hardware that the REU image reached the machine: run, then
# read the resident map blocks back out of C64 RAM and compare them against
# build/assets.reu. This is what Phase 1.2 could not check -- that the bytes
# FTP+REU-Preload delivers actually land in REU RAM.
u64-map: $(PRG) $(REUIMG) $(RELPRG) u64-config
	$(PYTHON) tools/u64push.py $(U64_HOST) $(PRG) --reu $(REUIMG) --verify-map

# Measure the real frame rate: run, then read the engine's frame counter
# twice over U64_FPS_SECONDS of wall clock.
U64_FPS_SECONDS ?= 10
u64-fps: $(PRG) $(REUIMG) $(RELPRG) u64-config
	$(PYTHON) tools/u64push.py $(U64_HOST) $(PRG) --reu $(REUIMG) \
	    --fps $(U64_FPS_SECONDS)

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
	rm -f build/*.prg build/*.sym build/*.vs build/*.reu build/*.png build/debug.log
