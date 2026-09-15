_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
# arm9-sysroot.sh — find an arm9 sysroot, once, for every harness that needs one.
#
# Sourced, not executed. Sets ARM9_SYSROOT to a directory containing libc.so,
# or leaves it empty. arm9 resolves `#import <c>` against the device libc.so, so
# without one the ORACLE cannot compile anything that imports Stdio and the
# sweep silently shrinks to what needs no libc — which is how a9-diff sat at 0
# passes and 853 skipped while printing "ok".
#
# Preference: an explicit override; then the INSTALLED sysroot, which is what
# `make install` vendors into lib/xc/arm9-sysroot and what `-A arm9` already
# uses as its default -L, so it is the copy a machine with a toolchain always
# has; then a loader build dir, for someone working on the loader itself.
# Newest install first, so 0.4 beats 0.3.
#
# Which one is chosen cannot change a RESULT: both sides of a differential get
# the same -L, and libc.so only has to declare the symbols. The tie-break is
# availability. It lives in ONE file because two harnesses need it and a
# duplicated path list is a list that drifts.
ARM9_SYSROOT=""
for _c in "${XTC_ARM9_SYSROOT:-}" \
          "lib/xc/arm9-sysroot" \
          $(ls -d /opt/xcc/*/lib/xc/arm9-sysroot 2>/dev/null | sort -rV); do
    [ -n "$_c" ] && [ -d "$_c" ] && [ -n "$(ls "$_c"/libc.so* 2>/dev/null)" ] \
        && { ARM9_SYSROOT="$_c"; break; }
done
