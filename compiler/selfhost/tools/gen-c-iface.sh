#!/bin/bash
# gen-c-iface.sh — regenerate the bundled libc interface stub.
# =================================================================
#
# On arm9 the driver AUTO-IMPORTS libc: it finds `libc.so` on the library path,
# reads the declarations out of its DWARF, and injects prototypes for the names
# the source mentions. The ported front end (`selfhost/`) has no DWARF reader,
# so it reads the same declarations out of `support/arm9/selfhost-iface/c.xc`.
#
# That file is GENERATED — the same contract as `selfhost/lexer/TokenType.xc`,
# which is generated from `XTTokenType.h`. Hand-editing it makes the two front
# ends disagree about a call's argument widths, and `fe-diff arm9` says so in
# whatever file happens to call the function.
#
#   bash selfhost/tools/gen-c-iface.sh [libdir]
#
# `xcc-fe --dump-c-iface` prints every function libc exports as an xtc
# declaration. Only the ones whose types the xtc language can SPELL are kept:
# a function taking `__sFILE@` or a function pointer needs the struct
# declarations too, which this stub does not carry — those names stay a
# measured gap rather than a wrong signature.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc-fe" ] || BIN=bin/linux
LIBDIR=${1:-${XTC_ARM9_SYSROOT:-}}
OUT=support/arm9/selfhost-iface/c.xc

if [ ! -d "$LIBDIR" ]; then
    echo "gen-c-iface: no library dir '$LIBDIR' — pass one, or set XTC_ARM9_SYSROOT" >&2
    exit 1
fi

WORK=${TMPDIR:-/tmp}/gciface.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
echo 'i32 main(void) { return (i32)0; }' > "$WORK/e.xc"

"$BIN/xcc-fe" -m arm9 -H . -L "$LIBDIR" --dump-c-iface "$WORK/e.xc" \
    > "$WORK/iface.txt" 2>"$WORK/err.txt" || { cat "$WORK/err.txt" >&2; exit 1; }

python3 - "$WORK/iface.txt" "$OUT" <<'PY'
import re, sys

src, out = sys.argv[1], sys.argv[2]
scalar = re.compile(r'^(i8|u8|i16|u16|i32|u32|i64|u64|float|double|bool|void)@*$')

# The dump is struct declarations first, then one function per line.
text = open(src).read()
structs = {}          # name -> source text
# The body is non-greedy and may be EMPTY (an opaque C type declares no
# fields), so the closing brace is matched on its own line either way.
for m in re.finditer(r'^struct (\w+)\n\{\n(.*?)^\}$', text, re.S | re.M):
    structs[m.group(1)] = m.group(0)

def normalise(t):
    """A C function-pointer type has no xtc source spelling that survives to
    the IR — the original lowers one to Ptr(Ptr(Void)), which is `void@@`.
    Read off the original's own IR, not invented."""
    return 'void@@' if '(' in t else t


def base(spelling):
    """The type NAME in a spelling — pointer and array suffixes stripped."""
    return re.split(r'[@\[]', spelling)[0]

def spellable(t, seen=None):
    """Can the port declare this type? Scalars always; a struct only if every
    field is itself spellable (the closure is what makes a layout match)."""
    if scalar.match(t):
        return True
    nm = base(t)
    if nm not in structs:
        return False
    seen = seen or set()
    if nm in seen:
        return True                      # a self-referential pointer is fine
    seen.add(nm)
    body = structs[nm].split('\n', 2)[2]
    for line in body.splitlines():
        line = line.strip().rstrip(';')
        if not line or line == '}':
            continue
        if not spellable(line.rsplit(' ', 1)[0], seen):
            return False
    return True

kept, needed, skipped = [], set(), 0
for line in text.splitlines():
    m = re.match(r'^(\S+) (\w+)\((.*)\);$', line.strip())
    if not m:
        continue
    ret, name, args = m.groups()
    types, variadic = [normalise(ret)], False
    if args not in ('void', ''):
        for a in args.split(', '):
            if a == '...':
                variadic = True
                continue
            types.append(normalise(a.rsplit(' ', 1)[0]))
    if not all(spellable(t) for t in types):
        skipped += 1
        continue
    for t in types:
        if not scalar.match(t):
            needed.add(base(t))
    # Parameter names are positional: libc's own spellings include words that
    # are RESERVED in xtc (`in`, `new`, `class`), and the name reaches nothing
    # the IR prints — a prototype has no body.
    ps = ['%s a%d' % (t, i) for i, t in enumerate(types[1:])]
    if variadic:
        ps.append('...')
    # types[0] is the NORMALISED return type, not the raw one. Emitting `ret`
    # here let a function-pointer return through verbatim — `void(i32)@@` — and
    # the parser has no spelling for that, so it stopped at the first one
    # (_signal_r) and SILENTLY DROPPED every declaration after it: ~2000 of
    # them, more than half the libc interface. Nothing reported it; the
    # declarations were simply not there.
    kept.append('%s %s(%s);' % (types[0], name, ', '.join(ps) if ps else 'void'))

# Everything the kept structs themselves reach, transitively.
work = list(needed)
while work:
    nm = work.pop()
    for line in structs[nm].split('\n', 2)[2].splitlines():
        line = line.strip().rstrip(';')
        if not line or line == '}':
            continue
        b = base(line.rsplit(' ', 1)[0])
        if b in structs and b not in needed:
            needed.add(b)
            work.append(b)

kept.sort(key=lambda l: re.match(r'^\S+ (\w+)\(', l).group(1))

with open(out, 'w') as f:
    f.write("""// c.xc — the libc declarations the ported front end cannot read for itself.
// =========================================================================
//
// GENERATED by `selfhost/tools/gen-c-iface.sh` from the DWARF in the arm9
// loader's `libc.so`. Do not hand-edit: the signatures are a CONTRACT with
// the original front end, which reads the same declarations out of the real
// libc, and a hand-tuned one diverges silently.
//
// On arm9 the driver auto-imports libc, so source calls `snprintf` and `write`
// without naming a header. The ported front end has no DWARF reader and reads
// this instead; `xtfe` injects only the names a unit actually mentions, plus
// the structs those names reach, and lets any declaration the program makes
// itself shadow the libc one — the rules the driver applies.
//
// A function whose types the language cannot SPELL (a function-pointer
// parameter, a struct with one inside) is left out rather than approximated:
// a guessed layout would put wrong offsets in optimised code, which is the
// one failure mode that does not look like a front-end bug.
//
// Functions are sorted by name — the DWARF importer hands its own back sorted,
// and that order is what makes the two symbol tables match.

""")
    for nm in sorted(needed):
        f.write(structs[nm] + '\n\n')
    f.write('\n'.join(kept) + '\n')

print('gen-c-iface: %d declarations, %d structs, %d skipped (unspellable types)'
      % (len(kept), len(needed), skipped))
PY
