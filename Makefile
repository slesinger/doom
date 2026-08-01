# Doom C64U — build system
#
# Targets:
#   make            build build/doom.prg
#   make run        run in VICE (16MB REU, assets image if present)
#   make shot       headless VICE run, screenshot to build/shot.png
#   make assets     convert DOOM1.WAD -> build/assets.reu (needs WAD in ./assets)
#   make run-u64    push PRG to Ultimate 64 over the network and run it
#   make clean

KICKASS   := java -jar /home/honza/projects/c64/pc-tools/kickass/KickAss.jar
VICE      := x64sc
PYTHON    := python3

# Ultimate 64 on the LAN — override like: make run-u64 U64_HOST=192.168.1.64
U64_HOST  ?= u64

SRC       := $(wildcard src/*.asm src/render/*.asm)
PRG       := build/doom.prg
REUIMG    := build/assets.reu
WAD       := assets/DOOM1.WAD

# VICE: 16 MB REU; attach the asset image read-only if it exists
REUOPTS    = -reu -reusize 16384
ifneq ($(wildcard $(REUIMG)),)
REUOPTS   += -reuimage $(REUIMG)
endif

.PHONY: all run shot assets run-u64 clean

all: $(PRG)

$(PRG): $(SRC)
	$(KICKASS) src/main.asm -odir ../build -o doom.prg -showmem \
	    -symbolfile -vicesymbols

run: $(PRG)
	$(VICE) $(REUOPTS) $(PRG)

# Headless-ish automated check: run warp for a while, dump a screenshot, exit.
SHOT_CYCLES ?= 50000000
shot: $(PRG)
	$(VICE) $(REUOPTS) -warp +confirmexit \
	    -limitcycles $(SHOT_CYCLES) -exitscreenshot build/shot.png $(PRG)

assets: $(REUIMG)

$(REUIMG): tools/wad2reu.py $(WAD)
	$(PYTHON) tools/wad2reu.py $(WAD) -o $(REUIMG)

run-u64: $(PRG)
	$(PYTHON) tools/u64push.py $(U64_HOST) $(PRG) --reu $(REUIMG)

clean:
	rm -f build/*.prg build/*.sym build/*.vs build/shot.png
