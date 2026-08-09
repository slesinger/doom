#!/usr/bin/env python3
"""Put the Ultimate into the machine configuration this engine expects.

The engine writes $D031 to select the CPU speed (see turboOn in
src/main.asm). That register only exists when the machine's Turbo
Control is set to "C64U Turbo Registers"; in any other mode it reads
$FF and the writes are ignored, so the engine silently runs at 1 MHz.
Rather than leave that as a thing you have to remember to set by hand in
the Ultimate's menu, this applies and verifies it over the REST API.

    python3 tools/u64config.py 192.168.1.65            # apply + verify
    python3 tools/u64config.py 192.168.1.65 --show     # report only
    python3 tools/u64config.py 192.168.1.65 --save     # + persist to flash

Without --save the settings are live but volatile: they survive a reset
but not a power cycle.
"""

from __future__ import annotations

import argparse
import sys

from u64 import Ultimate, U64Error, add_host_args

CATEGORY = "U64 Specific Settings"

# Why each of these:
#
#   Turbo Control       "C64U Turbo Registers" is the only setting that
#                       both takes the speed from the menu AND lets the
#                       running program change it via $D031. "Manual"
#                       locks the registers out; "TurboEnable Bit" moves
#                       control to $D030 and gives only on/off.
#   CPU Speed           64 MHz -- speed index 15 on this machine. This is
#                       the value $D031 = $0F selects.
#   Badline Timing      Enabled: keeps C64-compatible bus timing. The VIC
#                       has priority either way, so disabling it buys
#                       cycles at the cost of timing we may still want
#                       for the raster-synced buffer flip.
#   SuperCPU Detect     Disabled: nothing here probes $D0BC, and leaving
#                       the register unmapped keeps the I/O space honest.
PROFILE = {
    "Turbo Control": "C64U Turbo Registers",
    "CPU Speed": "64",
    "Badline Timing": "Enabled",
    "SuperCPU Detect (D0BC)": "Disabled",
}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    add_host_args(ap)
    ap.add_argument("--show", action="store_true",
                    help="report the current settings, change nothing")
    ap.add_argument("--save", action="store_true",
                    help="also write the configuration to flash so it "
                         "survives a power cycle")
    args = ap.parse_args(argv)

    u = Ultimate(args.host, args.password)

    try:
        info = u.info()
        print(f"{info.get('product', '?')} at {args.host} "
              f"(firmware {info.get('firmware_version', '?')}, "
              f"core {info.get('core_version', '?')})")

        current = u.get_category(CATEGORY)
        missing = [k for k in PROFILE if k not in current]
        if missing:
            print(f"error: this machine has no {missing} under "
                  f"{CATEGORY!r} -- is it an Ultimate 64?", file=sys.stderr)
            return 2

        changed = 0
        for item, want in PROFILE.items():
            have = str(current[item]).strip()
            if have == want:
                print(f"  ok      {item}: {have}")
                continue
            if args.show:
                print(f"  DIFFERS {item}: {have} (want {want})")
                changed += 1
                continue
            u.set_item(CATEGORY, item, want)
            print(f"  set     {item}: {have} -> {want}")
            changed += 1

        if args.show:
            return 1 if changed else 0

        # Read back rather than trusting the PUTs: the firmware silently
        # ignores a value that is not in the item's allowed list.
        after = u.get_category(CATEGORY)
        bad = {k: after.get(k) for k, v in PROFILE.items()
               if str(after.get(k, "")).strip() != v}
        if bad:
            print(f"error: settings did not stick: {bad}", file=sys.stderr)
            return 2

        if args.save:
            u.save_config_to_flash()
            print("  saved to flash")
        elif changed:
            print("  (not saved to flash -- pass --save to make it "
                  "survive a power cycle)")
    except U64Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
