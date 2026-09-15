#!/bin/sh
# bsp-flags.sh — emit the Cortex-A9 ABI flags (-mcpu/-mfpu/-mfloat-abi) the xtc
# A32 backend must match, read AUTOMATICALLY from the Vitis-generated BSP so a
# future platform change is picked up without editing anything here.
#
# Authoritative source (regenerated whenever create_platform.py reruns):
#   <hardware project>/.../standalone_ps7_cortexa9_0/bsp/cortexa9_toolchain.cmake
#       set( TOOLCHAIN_C_FLAGS " -DSDT -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard" ...)
#
# Set the search root with $XTC_ARM9_BSP in build.env (a cortexa9_toolchain.cmake path,
# or a dir to search). Falls back to the documented default with a stderr note
# if the BSP isn't built — never silent.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"

set -eu

DEFAULT="-mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard"

# Candidate toolchain.cmake locations (first hit wins).
cands=""
[ "${XTC_ARM9_BSP:-}" ] && cands="$XTC_ARM9_BSP"

tc=""
for c in $cands; do
    if [ -f "$c" ]; then tc="$c"; break; fi
    if [ -d "$c" ]; then
        f=$(find "$c" -name cortexa9_toolchain.cmake 2>/dev/null | head -1)
        [ -n "$f" ] && { tc="$f"; break; }
    fi
done

if [ -n "$tc" ] && [ -f "$tc" ]; then
    flags=$(grep -oE -- '-mcpu=[a-z0-9-]+|-mfpu=[a-z0-9-]+|-mfloat-abi=[a-z]+' "$tc" \
            | sort -u | tr '\n' ' ' | sed 's/ *$//')
    if [ -n "$flags" ]; then
        echo "arm9 ABI flags from $tc" >&2
        echo "$flags"
        exit 0
    fi
fi

echo "arm9 ABI flags: BSP not found — using documented default" >&2
echo "$DEFAULT"
