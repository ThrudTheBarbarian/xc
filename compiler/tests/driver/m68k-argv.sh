#!/bin/bash
# m68k-argv.sh — an Atari ST program's main gets argc and argv, as on every
# hosted target: the GEMDOS command tail split at spaces, after an empty
# argv[0] (TOS passes no program name), with argv[argc] null. Both compilers,
# -O0 and -O2, on the 68000 simulator.
set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
cd "$(dirname "$0")/../.." || exit 1
SIM=bin/$XC_PLAT/xcc-sim-68k
[ -x "$SIM" ] || { echo "m68k-argv: no 68000 simulator, skipped"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/argv.xc" <<'EOF'
#import "Stdio.xc"
i32 main(i32 argc, u8** argv)
    {
    Stdio.printf("argc %d\n", argc);
    for (i32 i = (i32)1; i < argc; i = i + (i32)1)
        Stdio.printf("[%s]\n", argv[i]);
    Stdio.printf("argv0 empty %d, argv[argc] null %d\n", argv[0][0] == (u8)0 ? 1 : 0, argv[argc] == (u8*)0 ? 1 : 0);
    return 0;
    }
EOF
printf 'argc 1\nargv0 empty 1, argv[argc] null 1\n' > "$W/none.want"
printf 'argc 4\n[one]\n[two]\n[three]\nargv0 empty 1, argv[argc] null 1\n' > "$W/three.want"
fail=0
for c in bin/$XC_PLAT/xcc bin/$XC_PLAT/xcc-xc; do
    [ -x "$c" ] || continue
    for o in -O0 -O2; do
        "$c" -q $o -A atarist -H . -o "$W/a.prg" "$W/argv.xc" > "$W/e" 2>&1 || { echo "FAIL $(basename "$c") $o: no build: $(head -c 300 "$W/e")"; fail=1; continue; }
        "$SIM" -d "$W/a.prg" 2>/dev/null | tr -d '\r' > "$W/none.got"
        "$SIM" -d --args "one  two three" "$W/a.prg" 2>/dev/null | tr -d '\r' > "$W/three.got"
        for k in none three; do
            if cmp -s "$W/$k.got" "$W/$k.want"; then echo "PASS $(basename "$c") $o ($k)"
            else echo "FAIL $(basename "$c") $o ($k):"; diff "$W/$k.want" "$W/$k.got" | sed 's/^/    /'; fail=1; fi
        done
    done
done
exit $fail
