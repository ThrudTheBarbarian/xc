# ptx-extract.py <program> <dir> — every PTX kernel a `par` program carries
# (win64 only), written as <dir>/<n>.ptx; prints the count. A PTX kernel is the
# NUL-terminated string the compiler embeds whose "// xcpar ..." header carries
# the `byval` marker; a SPIR-V-only block's header carries `spirv=` instead and
# does not match. parspv-diff.sh compares these so that a narrow int<->float
# conversion (which once sank the PTX kernel to a silent SPIR-V fallback, losing
# the CUDA card) cannot regress unseen, and so the two printers' PTX must agree
# byte for byte, the way their SPIR-V already must.
import sys, re
d = open(sys.argv[1], 'rb').read(); out = sys.argv[2]; n = 0
for m in re.finditer(rb'// xcpar[^\x00]*byval[^\x00]*\x00', d):
    open(f'{out}/{n}.ptx', 'wb').write(m.group(0)); n += 1
print(n)
