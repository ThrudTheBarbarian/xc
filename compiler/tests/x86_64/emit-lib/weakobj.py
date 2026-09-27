#!/usr/bin/env python3
# weakobj.py OUT.o — write a small x86-64 ELF relocatable object that refers
# to a WEAK undefined symbol, `weakthing`, which nothing defines.
#
#   i64 probe_got(void)   mov rax, [rip + weakthing@GOTPCREL]  (REX_GOTPCRELX)
#   i64 probe_word(void)  mov rax, [rip + wslot]               (wslot: .quad weakthing)
#
# Both return the address of `weakthing`, which must be 0 at run time. The
# object is written here rather than by a C compiler, so the test needs no
# toolchain beyond the one under test.
import struct, sys

text = bytes([0x48, 0x8b, 0x05, 0, 0, 0, 0, 0xc3,     # probe_got
              0x48, 0x8b, 0x05, 0, 0, 0, 0, 0xc3])    # probe_word
data = bytes(8)                                       # wslot

R_X86_64_64, R_X86_64_PC32, R_X86_64_REX_GOTPCRELX = 1, 2, 42
STB_LOCAL, STB_GLOBAL, STB_WEAK = 0, 1, 2
STT_NOTYPE, STT_OBJECT, STT_FUNC = 0, 1, 2
TEXT, DATA = 1, 2   # section indices

strtab = b"\0"
def name(s):
    global strtab
    off = len(strtab)
    strtab += s.encode() + b"\0"
    return off

# symbols: null, wslot (local), then the globals
syms = [(0, 0, 0, 0, 0)]
syms.append((name("wslot"), (STB_LOCAL << 4) | STT_OBJECT, DATA, 0, 8))
first_global = len(syms)
syms.append((name("probe_got"), (STB_GLOBAL << 4) | STT_FUNC, TEXT, 0, 8))
syms.append((name("probe_word"), (STB_GLOBAL << 4) | STT_FUNC, TEXT, 8, 8))
WEAK = len(syms)
syms.append((name("weakthing"), (STB_WEAK << 4) | STT_NOTYPE, 0, 0, 0))
symtab = b"".join(struct.pack("<IBBHQQ", n, info, 0, shndx, value, size)
                  for n, info, shndx, value, size in syms)

def rela(off, sym, typ, addend):
    return struct.pack("<QQq", off, (sym << 32) | typ, addend)
rela_text = rela(3, WEAK, R_X86_64_REX_GOTPCRELX, -4) + rela(11, 1, R_X86_64_PC32, -4)
rela_data = rela(0, WEAK, R_X86_64_64, 0)

shstr = b"\0"
def shname(s):
    global shstr
    off = len(shstr)
    shstr += s.encode() + b"\0"
    return off

# (name, type, flags, content, link, info, align, entsize)
secs = [None,
        (".text", 1, 6, text, 0, 0, 16, 0),
        (".data", 1, 3, data, 0, 0, 8, 0),
        (".rela.text", 4, 0x40, rela_text, 5, 1, 8, 24),
        (".rela.data", 4, 0x40, rela_data, 5, 2, 8, 24),
        (".symtab", 2, 0, symtab, 6, first_global, 8, 24),
        (".strtab", 3, 0, strtab, 0, 0, 1, 0),
        (".shstrtab", 3, 0, None, 0, 0, 1, 0)]
names = [0] + [shname(s[0]) for s in secs[1:]]
secs[7] = secs[7][:3] + (shstr,) + secs[7][4:]

body = b""
offs = [0]
pos = 64
for s in secs[1:]:
    pad = (-pos) % s[6]
    body += bytes(pad); pos += pad
    offs.append(pos)
    body += s[3]; pos += len(s[3])
pad = (-pos) % 8
body += bytes(pad); pos += pad
shoff = pos

ehdr = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8)
ehdr += struct.pack("<HHIQQQIHHHHHH", 1, 62, 1, 0, 0, shoff, 0, 64, 0, 0, 64, len(secs), 7)
shdrs = bytes(64)
for i, s in enumerate(secs[1:], 1):
    shdrs += struct.pack("<IIQQQQIIQQ", names[i], s[1], s[2], 0, offs[i], len(s[3]),
                         s[4], s[5], s[6], s[7])
open(sys.argv[1], "wb").write(ehdr + body + shdrs)
