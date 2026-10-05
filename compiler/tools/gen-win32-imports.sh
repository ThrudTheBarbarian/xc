#!/bin/sh
# gen-win32-imports.sh — generate support/win64/win32-imports.map, the
# symbol → DLL table the SELF-HOSTED win64 linker uses to resolve Win32 calls.
#
# Why this exists: the in-house PE writer can only emit an import for a symbol
# whose owning DLL it knows. Without this table its import list was a hardcoded
# handful of kernel32 entries (whatever the freestanding runtime needed), so any
# real Win32 call — GetStockObject, CreateWindowExA, InitCommonControls — failed
# to link. On a Mac that was masked by the fallback to mingw; on a Windows or
# Linux host with no mingw there is nothing to fall back to.
#
# The table is generated ONCE from a mingw sysroot and checked in, so the
# self-hosted path needs no mingw at build time — which is the whole point.
#
# Usage: tools/gen-win32-imports.sh [sysroot-lib-dir]
set -e
cd "$(dirname "$0")/.."
LIBDIR="${1:-${XTC_WIN64_TOOLCHAIN:-/opt/clang/win64}/x86_64-w64-mingw32/lib}"
NM="${XTC_WIN64_TOOLCHAIN:-/opt/clang/win64}/bin/x86_64-w64-mingw32-nm"
OUT=support/win64/win32-imports.map

[ -d "$LIBDIR" ] || { echo "gen-win32-imports: no sysroot lib dir '$LIBDIR'" >&2; exit 1; }
[ -x "$NM" ]     || { echo "gen-win32-imports: no nm at '$NM'" >&2; exit 1; }

# Order matters: a name exported by more than one DLL is attributed to the FIRST
# listed here, so the common/most-canonical owner wins deterministically.
#
# ucrtbase is LAST and is the C runtime, not a Win32 API: it is what mingw's
# snprintf reaches through (`__imp___stdio_common_vsprintf`). libucrt.a would
# spread the same symbols over the api-ms-win-crt-* API sets, which is more
# descriptors for no gain, so the single-DLL spelling is the one used.
DLLS="kernel32 user32 gdi32 advapi32 shell32 ole32 oleaut32 comctl32 comdlg32 winmm msimg32 winspool ws2_32 ucrtbase"

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
{
    echo "# win32-imports.map — symbol<TAB>DLL[<TAB>name the DLL exports], generated"
    echo "# by tools/gen-win32-imports.sh. The third column, when present, is the"
    echo "# export the symbol binds to (close -> _close)."
    echo "# Consumed by xcc-ln-win64 -importmap. Regenerate from a mingw sysroot; do"
    echo "# not hand-edit. Only symbols a program actually references are emitted"
    echo "# into its PE import table, so size here costs nothing in the output."
} > "$TMP"

seen=$(mktemp); exports=$(mktemp); aliases=$(mktemp); aliasPy=$(mktemp)
trap 'rm -f "$TMP" "$seen" "$exports" "$aliases" "$aliasPy"' EXIT

# An import library can bind one name to another export: mingw's libucrtbase.a
# gives `close` a stub whose import is ucrtbase's `_close`, because the DLL
# exports only the underscored POSIX names. Such a stub is a long-form import
# object, whose .idata$6 section holds the name actually imported. Those
# symbols get a third column, the DLL's own name, and the linkers import that:
# a program declaring close() then loads, where importing `close` itself fails
# before main with "entry point not found".
cat > "$aliasPy" <<'PY'
import struct, sys
def members(d):
    p = 8
    while p < len(d):
        size = int(d[p+48:p+58])
        yield d[p+60:p+60+size]
        p += 60 + size + (size & 1)
for m in members(open(sys.argv[1], 'rb').read()):
    if len(m) < 20 or struct.unpack('<H', m[:2])[0] != 0x8664:
        continue
    nsec, _, symptr, nsym = struct.unpack('<HIII', m[2:16])
    imported = None
    for k in range(nsec):
        h = m[20+k*40:60+k*40]
        if h[:8] == b'.idata$6':
            size, ptr = struct.unpack('<II', h[16:24])
            imported = m[ptr+2:ptr+size].split(b'\0')[0].decode('latin1')
    if not imported or not symptr:
        continue
    strtab = symptr + nsym * 18
    i = 0
    while i < nsym:
        e = m[symptr+i*18:symptr+i*18+18]
        if e[:4] == b'\0\0\0\0':
            off = struct.unpack('<I', e[4:8])[0]
            name = m[strtab+off:m.index(b'\0', strtab+off)]
        else:
            name = e[:8].rstrip(b'\0')
        sec, cls, naux = struct.unpack('<h', e[12:14])[0], e[16], e[17]
        name = name.decode('latin1')
        if cls == 2 and sec == 1 and name != imported:  # the stub, in .text
            print(name + "\t" + imported)
        i += 1 + naux
PY
: > "$seen"
for l in $DLLS; do
    a="$LIBDIR/lib$l.a"
    [ -f "$a" ] || continue
    # The DLL the archive imports from is recorded inside it; it is not always
    # lib<name>.dll (winspool → WINSPOOL.DRV), so read it rather than assume.
    dll=$(strings "$a" | grep -ioE "^[A-Za-z0-9_-]+\.(dll|drv)$" | sort -u | head -1)
    [ -n "$dll" ] || dll="$l.dll"
    # A symbol belongs in this table only if the DLL genuinely EXPORTS it. In an
    # import library that means an `__imp_<sym>` alongside it: the archive also
    # carries static code, and mapping such a name to a DLL produces a binary
    # that fails to LOAD — strictly worse than the link error it replaces.
    # libmsvcrt.a is the case that proves it: snprintf/printf/vsnprintf are all
    # mingw's own C99 objects, NOT msvcrt.dll exports, because msvcrt's are not
    # C99-conformant.
    "$NM" "$a" 2>/dev/null | grep -oE '__imp_[A-Za-z0-9_@?$.]+' | sed 's/^__imp_//' \
        | sort -u > "$exports"
    python3 "$aliasPy" "$a" > "$aliases"
    n=0
    for s in $("$NM" "$a" 2>/dev/null | awk '$2=="T"{print $3}' | sort -u); do
        case "$s" in ''|_head_*|__lib*|.*) continue;; esac
        grep -qxF "$s" "$exports" || continue   # static code, not a DLL export
        grep -qxF "$s" "$seen" && continue      # first DLL in DLLS order wins
        as=$(awk -F'\t' -v s="$s" '$1==s{print $2; exit}' "$aliases")
        if [ -n "$as" ]; then echo "$s	$dll	$as" >> "$TMP"; else echo "$s	$dll" >> "$TMP"; fi
        echo "$s" >> "$seen"
        n=$((n+1))
    done
    echo "  $l -> $dll ($n symbols)" >&2
done

mv "$TMP" "$OUT"; trap 'rm -f "$seen" "$exports" "$aliases" "$aliasPy"' EXIT
echo "wrote $OUT ($(grep -cv '^#' "$OUT") symbols)"
