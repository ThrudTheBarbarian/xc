#!/usr/bin/env python3
"""Regenerate support/x86_64/runtime/rtgen-linux.s from rt-freestanding.c.

The recipe is the one at the top of that source; the three pieces the header
calls "hand-applied" are re-applied here instead of by hand, so the file can be
regenerated reproducibly:

  * the licence + provenance header
  * _xt_main_tls_pad, 240 bytes reserved BELOW the main tcb
  * the _xtc_sinit_run tail
"""
import subprocess, sys, os
S = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CLANG = os.environ.get("XTC_RTGEN_CLANG", "clang")
out = subprocess.run([CLANG, "-S", "-O1", "-masm=intel",
    "-target", "x86_64-unknown-linux-gnu", "-fno-stack-protector",
    "-fomit-frame-pointer", "-fno-asynchronous-unwind-tables", "-fno-jump-tables",
    "-DXT_SINIT_C_INCLUDED=1", "-DXT_NO_WEAK_SEAM=1", "-o", "/dev/stdout",
    os.path.join(REPO, "src/xtc/support-src/rt-freestanding.c")],
    capture_output=True, text=True)
if out.returncode != 0:
    sys.exit("clang failed:\n" + out.stderr[-2000:])
body = out.stdout
hdr   = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "rtgen-pieces", "piece_header.txt")).read()
tlspad= open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "rtgen-pieces", "piece_tlspad.txt")).read()
sinit = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "rtgen-pieces", "piece_sinit.txt")).read()

# the tls pad replaces the plain _xt_main_tcb .bss preamble
old = ('\t.type\t_xt_main_tcb,@object            # @_xt_main_tcb\n'
       '\t.bss\n\t.globl\t_xt_main_tcb\n\t.p2align\t3, 0x0\n')
if old not in body:
    sys.exit("could not find the _xt_main_tcb .bss preamble to replace")
body = body.replace(old, tlspad, 1)
# the sinit tail goes at the very end
text = hdr + body.rstrip("\n") + "\n\n" + sinit
open(sys.argv[1] if len(sys.argv) > 1
     else os.path.join(REPO, "support/x86_64/runtime/rtgen-linux.s"), "w").write(text)
print("regenerated ->", sys.argv[1] if len(sys.argv) > 1 else "(in place)")
