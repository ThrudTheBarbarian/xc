#!/bin/sh
# check-install.sh — guard the install step, which has broken twice and both times looked like a
# compiler bug that was already fixed.
#
# Task #1000 and Task #1005 were the same defect in different rules: a binary the Makefile builds
# was never installed, so the repo had the fix and the developer's PATH did not.  Nothing
# caught it, because everything downstream of the compiler tests the compiler — and the compiler
# under test was the freshly-built one in bin/, not the stale one everyone else was running.  The
# symptom reaches whoever is using the toolchain, days later, as a bug that "still reproduces".
#
# Two checks, deliberately different in kind:
#
#   RULES   Every shipped binary is listed in INSTALL_BINS, so `make install` ships it.  A property
#           of the repo alone — no environment, no timing, same answer on every machine — so this is
#           a hard failure, and it is the one that catches #1000/#1005 when the rule is written.
#           (Before 0.4 each rule copied itself to ~/bin as a build side effect; installing is now
#           an explicit `make install` to a versioned prefix, so the invariant moved with it.)
#
#   PATH    The binary that would actually RUN matches the one in bin/.  Environment-dependent, so
#           it fails only on unambiguous staleness: the files differ AND the build is newer.  A
#           developer deliberately running a released toolchain gets a note, not a failure, and can
#           silence it with XTC_ALLOW_STALE_PATH=1.
#
# Exit 0 = both clean.  Exit 1 = a real problem.
set -u
cd "$(dirname "$0")/.." || exit 1

BIN_DIR=${BIN_DIR:-bin/osx}
[ -d "$BIN_DIR" ] || BIN_DIR=bin/linux

# Binaries the Makefile builds into BIN_DIR that are NOT meant to be on anyone's PATH: test drivers,
# the corpus sweep, and the assembler oracles.  Everything else is shipped, and adding a new tool
# without adding it here means the RULES check demands an install step for it — which is the point.
NOT_SHIPPED="xtc_tests xtc_corpus_sweep oracle-arm64 oracle-x86_64 oracle-elfobj elfobjdump oracle-coffobj coffobjdump macho-smoke test_ir_lowering test_xt6502"
# xcc-as-xc is built ahead of the install step that ships it as xcc-as. Remove
# it from this list when that `$(CP) $(XCC_AS_XC_BIN)` lands in the install rule.
NOT_SHIPPED="$NOT_SHIPPED xcc-as-xc"

fails=0
notes=0
notonpath=0

# ---- RULES ---------------------------------------------------------------------------------
# Two passes over the Makefile: collect VAR -> binary name for every `X_BIN = $(BIN_DIR)/name`,
# then walk each `$(VAR):` rule's recipe (the indented block that follows) looking for the copy.
missing=$(awk '
  # Pass 1: VAR -> binary name, for every `X_BIN = $(BIN_DIR)/name`.
  NR==FNR {
    if ($0 ~ /^[A-Za-z0-9_]+_BIN[ \t]*:?=[ \t]*\$\(BIN_DIR\)\//) {
      var = $1
      line = $0
      sub(/^.*\$\(BIN_DIR\)\//, "", line)
      sub(/[ \t].*$/, "", line)
      name[var] = line
    }
    next
  }
  # Pass 2: the INSTALL_BINS list (a backslash-continued assignment).
  /^INSTALL_BINS[ \t]*=/ { collecting = 1 }
  collecting {
    line = $0
    while (match(line, /\$\([A-Za-z0-9_]+_BIN\)/)) {
      v = substr(line, RSTART + 2, RLENGTH - 3)
      shipped[v] = 1
      line = substr(line, RSTART + RLENGTH)
    }
    if ($0 !~ /\\$/) collecting = 0
    next
  }
  # ...and any binary the install rule copies by hand.  A tool can ship under a
  # DIFFERENT name than it is built as — the xc-built compiler installs as plain
  # `xcc`, because that is the compiler developers get — and such a copy is a
  # real install, not a gap.  Matching the copy itself keeps the check live: a
  # binary that is neither listed nor copied still fails, which an exemption
  # list would not have caught.
  /\$\(CP\)[ \t]*\$\([A-Za-z0-9_]+_BIN\)[ \t]*"?\$\(BINDIR\)/ {
    line = $0
    if (match(line, /\$\([A-Za-z0-9_]+_BIN\)/)) {
      shipped[substr(line, RSTART + 2, RLENGTH - 3)] = 1
    }
    next
  }
  END { for (v in name) if (!(v in shipped)) print name[v] }
' Makefile Makefile | sort -u)

for b in $missing; do
    skip=0
    for n in $NOT_SHIPPED; do [ "$b" = "$n" ] && skip=1; done
    [ "$skip" = 1 ] && continue
    echo "FAIL  $b: the Makefile builds it but INSTALL_BINS does not ship it"
    echo "      (this is Task #1000 / #1005 exactly: the repo gets the fix, the PATH does not)"
    fails=$((fails + 1))
done

# ---- PATH ----------------------------------------------------------------------------------
# Only for binaries that have actually been built — an unbuilt tool is not drift.
for path in "$BIN_DIR"/*; do
    [ -f "$path" ] || continue
    case "$path" in *.d|*.dSYM*) continue ;; esac
    [ -x "$path" ] || continue
    b=$(basename "$path")
    skip=0
    for n in $NOT_SHIPPED; do [ "$b" = "$n" ] && skip=1; done
    [ "$skip" = 1 ] && continue

    onpath=$(command -v "$b" 2>/dev/null) || onpath=""
    if [ -z "$onpath" ]; then
        # Counted, reported once at the end. Fourteen identical lines saying the
        # toolchain is not installed is noise that trains people to skip the
        # whole report.
        notonpath=$((notonpath + 1))
        continue
    fi
    # Same file (a symlink or a PATH entry pointing straight at bin/) is trivially fine.
    [ "$onpath" -ef "$path" ] && continue
    if cmp -s "$path" "$onpath"; then continue; fi

    if [ "$path" -nt "$onpath" ]; then
        echo "FAIL  $b: the copy on PATH is STALE"
        echo "      built:   $path"
        echo "      running: $onpath"
        echo "      A test that fails against the running one and passes against the built one is"
        echo "      not a compiler bug.  Run make, or set XTC_ALLOW_STALE_PATH=1 if this is deliberate."
        if [ "${XTC_ALLOW_STALE_PATH:-0}" = "1" ]; then
            echo "      (XTC_ALLOW_STALE_PATH=1 — not counted as a failure)"
        else
            fails=$((fails + 1))
        fi
    else
        echo "note  $b: differs from $onpath, which is not older than the build — not stale, just not ours"
        notes=$((notes + 1))
    fi
done

if [ "$notonpath" -gt 0 ]; then
    echo "note  $notonpath built binary/binaries are not on PATH — run 'make install'"
    echo "      and put the printed bin directory on PATH (default /opt/xcc/<version>/bin)."
    notes=$((notes + 1))
fi

if [ "$fails" -gt 0 ]; then
    echo ""
    echo "=== check-install: $fails problem(s) ==="
    exit 1
fi
if [ "$notes" -gt 0 ]; then
    echo "=== check-install: OK ($notes note(s) above are not failures) ==="
else
    echo "=== check-install: OK (every shipped binary installs, and PATH matches the build) ==="
fi
exit 0
