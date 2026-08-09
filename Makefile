# Doom C64U — build system
#
# Targets:
#   make            build build/doom.prg
#   make run        run in VICE (128K REU preloaded with build/assets.reu)
#   make shot       headless VICE run, screenshot to build/shot.png
#   make check      the regression gate: build + shot content + live-RAM diff
#   make debug      live-RAM vs PRG diff under the VICE binary monitor
#   make assets     DOOM1.WAD -> build/assets.reu, plus build/testmap.reu
#   make u64-config apply the required turbo settings to the Ultimate
#   make run-u64    push PRG to the Ultimate over the network and run it
#   make u64-fps    run on the Ultimate and measure the real frame rate
#   make u64-map    run on the Ultimate and verify the REU map image landed
#   make reubench   measure REU DMA throughput on the Ultimate
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
REUIMG    := build/assets.reu
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

.PHONY: all run shot check debug assets reubench run-u64 u64-config u64-fps \
        u64-map setup clean

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

# The map images. Both go through the same packers in wad2reu.py; the format
# they share is frozen in docs/reu-format.md.
#
# testmap.reu is the 3-sector map of src/testmap.asm run through a BSP builder
# in the tool. It exists so the BSP traversal can be brought up on geometry
# that is 16 segs and already hand-traced (pipeline.md §11) before E1M1's 732
# segs are involved -- i.e. so a garbled first frame can be blamed on the
# converter or on the traversal, but not on both at once.
assets: $(REUIMG) $(TESTREU)

$(REUIMG): tools/wad2reu.py $(WAD)
	$(PYTHON) tools/wad2reu.py $(WAD) -o $(REUIMG)

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

clean:
	rm -f build/*.prg build/*.sym build/*.vs build/*.reu build/*.png build/debug.log
