# Doom C64U — build system
#
# Targets:
#   make            build build/doom.prg
#   make run        run in VICE (16MB REU, assets image if present)
#   make shot       headless VICE run, screenshot to build/shot.png
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

.PHONY: all run shot debug assets run-u64 setup clean

setup:
	sh tools/setup-dev-env.sh

all: $(PRG)

$(PRG): $(SRC)
	$(KICKASS) src/main.asm -odir build -o $(PRG) -showmem \
	    -symbolfile -vicesymbols

run: $(PRG)
	$(VICEWRAP) $(VICE) $(REUOPTS) $(VICEOPTS) -autostart $(PRG)

# Headless-ish automated check: run warp for a while, dump a screenshot, exit.
SHOT_CYCLES ?= 50000000
shot: $(PRG)
	$(VICEWRAP) $(VICE) $(REUOPTS) $(VICEOPTS) -warp \
	    -limitcycles $(SHOT_CYCLES) -exitscreenshot build/shot.png \
	    -autostart $(PRG)

assets: $(REUIMG)

$(REUIMG): tools/wad2reu.py $(WAD)
	$(PYTHON) tools/wad2reu.py $(WAD) -o $(REUIMG)

run-u64: $(PRG)
	$(PYTHON) tools/u64push.py $(U64_HOST) $(PRG) --reu $(REUIMG)

# Run under the binary monitor and diff live RAM against the PRG image; a clean
# run reports no writes outside the engine's own buffers. See tools/vicedbg.
MONPORT ?= 6510
debug: $(PRG)
	$(VICEWRAP) $(VICE) $(REUOPTS) $(VICEOPTS) -warp \
	    -binarymonitor -binarymonitoraddress ip4://127.0.0.1:$(MONPORT) \
	    -autostart $(PRG) & \
	sleep 4; $(PYTHON) tools/vicedbg/probe.py diff $(PRG) $(MONPORT)

clean:
	rm -f build/*.prg build/*.sym build/*.vs build/shot.png
