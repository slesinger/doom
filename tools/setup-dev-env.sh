#!/bin/sh
# Set up a headless build/test environment for Doom C64U.
#
# Installs VICE and the C64 ROMs it needs. The Debian/Ubuntu `vice` package is
# built from a DFSG-stripped tarball with the ROMs removed, so x64sc refuses to
# start ("Couldn't load kernal ROM"); we restore them from VICE's own upstream
# tree.
#
# KickAssembler is NOT installed here: it is only distributed from theweb.dk,
# which is not reachable from every environment. Drop KickAss.jar in
# tools/kickass/ or point KICKASS_JAR at it -- see the Makefile.
set -eu

VICE_ROMS="https://raw.githubusercontent.com/VICE-Team/svn-mirror/main/vice/data/C64"
ROM_DIR="${ROM_DIR:-/usr/share/vice/C64}"

echo "==> installing VICE + xvfb"
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y vice xvfb
else
    echo "    no apt-get; install 'vice' and 'xvfb' by hand" >&2
fi

echo "==> fetching C64 ROMs into $ROM_DIR"
mkdir -p "$ROM_DIR"
for rom in kernal-901227-03.bin basic-901226-01.bin chargen-901225-01.bin; do
    if [ -s "$ROM_DIR/$rom" ]; then
        echo "    $rom already present"
    else
        curl -fsSL -o "$ROM_DIR/$rom" "$VICE_ROMS/$rom"
        echo "    $rom"
    fi
done

echo "==> checking"
command -v x64sc  >/dev/null 2>&1 && echo "    x64sc:    $(command -v x64sc)"
command -v xvfb-run >/dev/null 2>&1 && echo "    xvfb-run: $(command -v xvfb-run)"
if [ -n "${KICKASS_JAR:-}" ] && [ -f "${KICKASS_JAR}" ]; then
    echo "    KickAss:  $KICKASS_JAR"
elif [ -f tools/kickass/KickAss.jar ]; then
    echo "    KickAss:  tools/kickass/KickAss.jar"
else
    echo "    KickAss:  MISSING -- 'make' will not work until you supply it"
fi

echo "done. Try:  make shot VICEWRAP='xvfb-run -a'"
