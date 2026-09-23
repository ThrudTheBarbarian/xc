#!/bin/sh
# elfobj-diff.sh — the two ELF object readers must agree.
#
# The reference reads foreign ELF64 relocatables in XTElfWriter's
# `objectFromData:`; the port reads them in selfhost/asm/ElfObject.xc. Linking
# against a real libc depends on both agreeing about what an object CONTAINS,
# and the interesting failures are not missing symbols — they are symbols filed
# under the wrong blob, or a blob whose alignment is understated. So the
# compared text carries the classification and the relocations, not just names.
#
# Inputs, in order of preference:
#   * musl's libc.a — 1345 real members, the volume case
#   * generated objects covering what libc.a does NOT contain: thread-local
#     storage and COMMON symbols, both of which were dead code against libc.a
#     alone. The COMMON one caught a live under-alignment bug in the reference.
#
# Skips cleanly (SKIP, not PASS) when no x86-64 ELF input can be found.
set -u
cd "$(dirname "$0")/../.." || exit 1

BIN_DIR=${BIN_DIR:-bin/osx}
[ -d "$BIN_DIR" ] || BIN_DIR=bin/linux
ORACLE="$BIN_DIR/oracle-elfobj"
PORT="$BIN_DIR/elfobjdump"

MUSL=${XTC_MUSL_ROOT:-/opt/clang/linux/x86_64-linux-musl}
CC=${XTC_MUSL_CC:-/opt/clang/linux/bin/x86_64-linux-musl-clang}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Build both sides if absent — the other harnesses build their port tool too,
# so a missing binary is a stale tree, not a reason to report nothing.
[ -x "$ORACLE" ] || make -s oracle-elfobj >/dev/null 2>&1
[ -x "$PORT" ]   || make -s elfobjdump    >/dev/null 2>&1
# No pass=/fail= line here on purpose: all-diff scores a harness that COMPARED
# NOTHING as BROKEN, and a reader differential that could not run is exactly
# that. Loud beats a green row that checked nothing.
[ -x "$ORACLE" ] || { echo "--- elfobj-diff: DID NOT RUN (cannot build oracle-elfobj) ---"; exit 1; }
[ -x "$PORT" ]   || { echo "--- elfobj-diff: DID NOT RUN (cannot build elfobjdump) ---"; exit 1; }

inputs=""
[ -f "$MUSL/lib/libc.a" ] && inputs="$MUSL/lib/libc.a"

# The generated cases. libc.a has no .tdata/.tbss and no COMMON anywhere, so
# without these the TLS and COMMON branches are never executed by this harness
# and a divergence in them would read as a clean pass.
if [ -x "$CC" ]; then
    cat > "$WORK/tls.c" <<'CEOF'
__thread int tls_counter = 7;
__thread long tls_zero;
__thread char tls_buf[64];
static __thread int tls_hidden = 3;
int common_var;
extern int outside(int);
int bump(int n) { tls_counter += n; tls_zero += n; tls_buf[0] = (char)n;
                  tls_hidden += n; common_var += n; return outside(tls_counter); }
CEOF
    cat > "$WORK/com.c" <<'CEOF'
double big[64];          /* tentative: COMMON, clang aligns it to 16 */
char   small[3];
int use(int i) { return (int)big[i] + small[0]; }
CEOF
    "$CC" -c -O2 -fcommon -ffunction-sections -fdata-sections \
          -o "$WORK/tls.o" "$WORK/tls.c" 2>/dev/null && inputs="$inputs $WORK/tls.o"
    "$CC" -c -O2 -fcommon -o "$WORK/com.o" "$WORK/com.c" 2>/dev/null && inputs="$inputs $WORK/com.o"
fi

if [ -z "$inputs" ]; then
    echo "--- elfobj-diff: SKIPPED (no x86-64 ELF input; set XTC_MUSL_ROOT or XTC_MUSL_CC) ---"
    exit 0
fi

pass=0; fail=0
for in in $inputs; do
    "$ORACLE" "$in" > "$WORK/o.txt" 2>/dev/null
    "$PORT"   "$in" > "$WORK/p.txt" 2>/dev/null
    if [ ! -s "$WORK/o.txt" ]; then
        echo "    $(basename "$in"): oracle produced nothing — NOT a pass"
        fail=$((fail + 1)); continue
    fi
    if cmp -s "$WORK/o.txt" "$WORK/p.txt"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "    $(basename "$in"): differs"
        diff "$WORK/o.txt" "$WORK/p.txt" | head -6 | sed 's/^/      /'
    fi
done
echo "--- elfobj-diff: pass=$pass fail=$fail ---"
# NOTHING COMPARED is not a pass. An oracle failure — a file the REFERENCE could
# not build — is skipped, so a broken oracle turns the whole sweep into skips
# and the summary reads pass=0 fail=0. Only `fail` was ever checked, so that
# exited 0 and showed as a clean row in all-diff's table; it hid 961 uncompared
# files on ldx86-diff. private:docs/bugs/239.
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi
[ "$fail" = 0 ]
