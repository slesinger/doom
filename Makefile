# Doom C64U — build system
#
# Targets:
#   make            build build/doom.prg
#   make run        run in VICE (16MB REU, assets image if present)
#   make shot       headless VICE run, screenshot to build/shot.png
#   make check      the regression gate: build + shot content + live-RAM diff
#   make debug      live-RAM vs PRG diff under the VICE binary monitor
#   make assets     convert DOOM1.WAD -> build/assets.reu (needs WAD in ./assets)
#   make run-u64    push PRG to Ultimate 64 over the network and run it
#   make clean

# KickAssembler is only distributed from theweb.dk; keep the location
# overridable so CI / containers can supply their own copy.
KICKASS_JAR ?= /home/honza/projects/c64/pc-tools/kickass/KickAss.jar
KICKASS   := java -jar $(KICKASS_JAR)
VICE      ?= x64sc
# set to "xvfb-run -a" on a headless machine
VICEWRAP  ?=
PYTHON    := python3

# Ultimate 64 on the LAN — override like: make run-u64 U64_HOST=192.168.1.64
U64_HOST  ?= u64

SRC       := $(wildcard src/*.asm src/render/*.asm)
PRG       := build/doom.prg
REUIMG    := build/assets.reu
WAD       := assets/DOOM1.WAD

# VICE: 16 MB REU; attach the asset image read-only if it exists
REUOPTS    = -reu -reusize 16384
# +confirmexit is not a VICE option (VICE bails out); it is +confirmonexit.
# -autostartprgmode 1 injects the PRG directly, so no 1541 drive ROMs are
# needed. +sound keeps a missing audio device from killing a headless run.
# -default ignores this machine's saved vicerc: a vicerc left behind by some
# other VICE project (e.g. a cartridge or drive ROM override) can silently
# break -autostart, which fails open into a blank BASIC READY screen that
# looks a lot like -- but is not -- our own black-screen bug. shot/debug
# must be hermetic against whatever else has run x64sc on this machine.
VICEOPTS   = -default +confirmonexit -autostartprgmode 1 +sound
ifneq ($(wildcard $(REUIMG)),)
REUOPTS   += -reuimage $(REUIMG)
endif

.PHONY: all run shot check debug assets run-u64 setup clean

# `setup` is defined first for readability but must not be the default goal:
# a bare `make` has to build, as the README says it does.
.DEFAULT_GOAL := all

setup:
	sh tools/setup-dev-env.sh

all: $(PRG)

$(PRG): $(SRC)
	$(KICKASS) src/main.asm -odir build -o $(PRG) -showmem \
	    -symbolfile -vicesymbols

run: $(PRG)
	$(VICEWRAP) $(VICE) $(REUOPTS) $(VICEOPTS) -autostart $(PRG)

# Headless-ish automated check: run warp for a while, dump a screenshot, exit.
#
# x64sc exits non-zero when -limitcycles stops it, which is the *expected* end
# of this run -- so its status says nothing about success. Ignore it and judge
# the run by its artifact instead: the PNG must exist and be newer than the
# PRG. `make check` then judges the PNG's content.
SHOT_CYCLES ?= 50000000
SHOT        := build/shot.png
shot: $(PRG)
	rm -f $(SHOT)
	-$(VICEWRAP) $(VICE) $(REUOPTS) $(VICEOPTS) -warp \
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

assets: $(REUIMG)

$(REUIMG): tools/wad2reu.py $(WAD)
	$(PYTHON) tools/wad2reu.py $(WAD) -o $(REUIMG)

run-u64: $(PRG)
	$(PYTHON) tools/u64push.py $(U64_HOST) $(PRG) --reu $(REUIMG)

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
debug: $(PRG)
	@mkdir -p build
	$(VICEWRAP) $(VICE) $(REUOPTS) $(VICEOPTS) -warp \
	    -binarymonitor -binarymonitoraddress ip4://127.0.0.1:$(MONPORT) \
	    -autostart $(PRG) > $(VICELOG) 2>&1 & \
	vpid=$$!; \
	$(PYTHON) tools/vicedbg/probe.py diff $(PRG) $(MONPORT); rc=$$?; \
	pkill -P $$vpid 2>/dev/null; kill $$vpid 2>/dev/null; \
	exit $$rc

clean:
	rm -f build/*.prg build/*.sym build/*.vs build/shot.png build/debug.log
