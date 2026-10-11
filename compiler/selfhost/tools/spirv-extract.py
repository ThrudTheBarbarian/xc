# spirv-extract.py <program> <dir> — every SPIR-V kernel a `par` program carries,
# written as <dir>/<n>.spv; prints the count. The kernel sits in the string the
# compiler embeds: a "// xcpar ..." header line naming spirv=<words>, a NUL,
# padding to a four-byte boundary, then the words. On win64 the PTX comes first
# and the SPIR-V follows it.
#
# Used by parspv-diff.sh, which needs the module itself (not just its validity)
# to compare the two compilers' printers: the gate's par-spirv-val runs these
# through spirv-val, which cannot tell two valid modules apart.
import sys, re, struct
d = open(sys.argv[1], 'rb').read(); out = sys.argv[2]; n = 0
for m in re.finditer(rb'spirv=(\d+)', d):
    words = int(m.group(1))
    st = d.rfind(b'//', 0, m.start())
    if st < 0 or b'\0' in d[st:m.start()]: continue
    end = d.index(b'\0', m.start())
    at = ((end - st) + 4) & ~3
    blob = d[st + at: st + at + words * 4]
    if blob[:4] != struct.pack('<I', 0x07230203): continue
    open(f'{out}/{n}.spv', 'wb').write(blob); n += 1
print(n)
