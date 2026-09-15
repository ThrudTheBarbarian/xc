#!/bin/bash
# End-to-end proof for the self-hosted toolchain: assemble a program with
# XAArm64Assembler, emit an executable with XTMachOWriter (which now writes its
# OWN ad-hoc code signature — Phase 3), run it directly (NO external codesign),
# and check the exit code / stdout. 100% self-produced. macOS/arm64 only.
set -e
cd "$(dirname "$0")/../.."
BIN=bin/osx/macho-smoke
[ -x "$BIN" ] || { echo "build first: make macho-smoke"; exit 1; }
fail=0
run() { # name  src-file  expected-exit  [expected-stdout]
  "$BIN" "$2" /tmp/xt-macho-$$
  chmod +x /tmp/xt-macho-$$; set +e; out=$(/tmp/xt-macho-$$); got=$?; set -e
  ok=1; [ "$got" = "$3" ] || ok=0; [ -z "$4" ] || [ "$out" = "$4" ] || ok=0
  if [ "$ok" = 1 ]; then echo "  PASS: $1 (exit $got${4:+, out='$out'})";
  else echo "  FAIL: $1 (exit $got want $3; out='$out' want '$4')"; fail=1; fi
  rm -f /tmp/xt-macho-$$
}
printf '_main:\nmovz w0, #42\nret\n' > /tmp/p1.s
run "return 42 (no imports)" /tmp/p1.s 42
printf '_main:\nmov w0,#0\nmov w1,#1\nL:\nadd w0,w0,w1\nadd w1,w1,#1\ncmp w1,#10\nb.lo L\nret\n' > /tmp/p2.s
run "sum 1..9 = 45 (local branch)" /tmp/p2.s 45
printf '_main:\nmovz w0, #42\nbl _exit\n' > /tmp/p3.s
run "exit(42) (1 import)" /tmp/p3.s 42
printf '_main:\nsub sp,sp,#16\nmov w0,#72\nstrb w0,[sp]\nmov w0,#105\nstrb w0,[sp,#1]\nmov w0,#10\nstrb w0,[sp,#2]\nmov w0,#1\nmov x1,sp\nmov w2,#3\nbl _write\nmov w0,#0\nadd sp,sp,#16\nbl _exit\n' > /tmp/p4.s
run "write(Hi) + exit(0) (2 imports)" /tmp/p4.s 0 "Hi"
# a string constant in __DATA, reached via adrp/add (PAGE21/PAGEOFF12 fixups)
printf '.text\n_main:\nadrp x1, _m@PAGE\nadd x1, x1, _m@PAGEOFF\nmov w0,#1\nmov w2,#6\nbl _write\nmov w0,#0\nbl _exit\n.section __DATA,__data\n_m:\n.asciz "data!\\n"\n' > /tmp/p5.s
run "__DATA string via adrp/add" /tmp/p5.s 0 "data!"
exit $fail
