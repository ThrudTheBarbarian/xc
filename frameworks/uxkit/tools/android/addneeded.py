#!/usr/bin/env python3
# addneeded.py — add a DT_NEEDED entry to an ELF64 shared object, in place.
#
# Why this exists: `xcc -A android`'s payload lib imports the driver shim's
# ux_and_* symbols, and bionic resolves a dlopen'd lib's imports only against
# its own local group (itself + DT_NEEDED deps) plus the global group — and
# it does NOT honour RTLD_GLOBAL promotion of an already-loaded library, so
# the shim can't inject itself.  A NEEDED entry on the app lib is the one
# arrangement the loader always honours.  The in-house linker has no flag
# for extra needed libs (yet — see private:docs/bugs/031's sibling ask), hence this
# post-link patch.
#
# Mechanism (no section moves, loader-view only): the new dynamic array and
# the needed string go into the zero padding after the PT_LOAD that holds
# .dynstr (the in-house layout leaves whole pages of it); that segment's
# filesz/memsz grow to cover them; PT_DYNAMIC is repointed; DT_STRSZ in the
# NEW array is bumped so the string offset passes bionic's bounds check.
# The old .dynamic bytes stay put — section headers still describe them,
# which only tools read; the loader reads phdrs.
#
# usage: addneeded.py <lib.so> <needed-name>
import struct, sys

path, needed = sys.argv[1], sys.argv[2]
d = bytearray(open(path, "rb").read())

assert d[:4] == b"\x7fELF" and d[4] == 2, "not ELF64"
e_phoff, = struct.unpack_from("<Q", d, 0x20)
e_phentsize, e_phnum = struct.unpack_from("<HH", d, 0x36)

phdrs = []
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    ptype, flags, poff, vaddr, paddr, filesz, memsz, align = \
        struct.unpack_from("<IIQQQQQQ", d, off)
    phdrs.append(dict(i=i, off=off, type=ptype, flags=flags, poff=poff,
                      vaddr=vaddr, filesz=filesz, memsz=memsz, align=align))

PT_LOAD, PT_DYNAMIC = 1, 2
dyn = next(p for p in phdrs if p["type"] == PT_DYNAMIC)

# the current dynamic entries (minus the terminator)
entries = []
for i in range(dyn["filesz"] // 16):
    tag, val = struct.unpack_from("<qQ", d, dyn["poff"] + i * 16)
    if tag == 0:
        break
    entries.append([tag, val])
strtab_vaddr = next(v for t, v in entries if t == 5)   # DT_STRTAB

# the hole: after the file content of the PT_LOAD holding .dynstr
host = next(p for p in phdrs if p["type"] == PT_LOAD
            and p["vaddr"] <= strtab_vaddr < p["vaddr"] + p["filesz"])
hole = (host["poff"] + host["filesz"] + 7) & ~7
name = needed.encode() + b"\0"
need = len(name) + 8 + 16 * (len(entries) + 2)         # string + align + array
limit = min([p["poff"] for p in phdrs if p["type"] == PT_LOAD and p["poff"] > hole]
            + [len(d)])
mlimit = min([p["vaddr"] for p in phdrs if p["type"] == PT_LOAD and p["vaddr"] > host["vaddr"]]
             + [1 << 62])
assert hole + need <= limit, "no file hole after the strtab segment"
assert d[host["poff"] + host["filesz"]:hole + need].count(0) == \
       hole + need - host["poff"] - host["filesz"], "hole is not zero padding"

str_off = hole
str_vaddr = host["vaddr"] + (str_off - host["poff"])
dyn_off = (str_off + len(name) + 7) & ~7
dyn_vaddr = host["vaddr"] + (dyn_off - host["poff"])
assert dyn_vaddr + 16 * (len(entries) + 2) <= mlimit, "no memory room in the segment"

d[str_off:str_off + len(name)] = name
new = [[1, str_vaddr - strtab_vaddr]]                  # DT_NEEDED, first
for tag, val in entries:
    if tag == 10:                                      # DT_STRSZ: cover the new string
        val = str_vaddr - strtab_vaddr + len(name)
    new.append([tag, val])
new.append([0, 0])                                     # DT_NULL terminator
for i, (tag, val) in enumerate(new):
    struct.pack_into("<qQ", d, dyn_off + i * 16, tag, val)

grown = dyn_off + 16 * len(new) - host["poff"]
struct.pack_into("<QQ", d, host["off"] + 0x20, grown, grown)      # filesz, memsz
struct.pack_into("<QQQ", d, dyn["off"] + 0x08, dyn_off, dyn_vaddr, dyn_vaddr)
struct.pack_into("<QQ", d, dyn["off"] + 0x20, 16 * len(new), 16 * len(new))

# bionic checks the SHT_DYNAMIC section header against PT_DYNAMIC — move it too
e_shoff, = struct.unpack_from("<Q", d, 0x28)
e_shentsize, e_shnum = struct.unpack_from("<HH", d, 0x3A)
for i in range(e_shnum):
    soff = e_shoff + i * e_shentsize
    stype, = struct.unpack_from("<I", d, soff + 4)
    saddr, = struct.unpack_from("<Q", d, soff + 0x10)
    if stype == 6:                                     # SHT_DYNAMIC
        struct.pack_into("<QQQ", d, soff + 0x10, dyn_vaddr, dyn_off, 16 * len(new))
    elif stype == 3 and saddr == strtab_vaddr:         # SHT_STRTAB (.dynstr):
        # bionic's ElfReader takes strtab_size_ from HERE, not DT_STRSZ
        struct.pack_into("<Q", d, soff + 0x20, str_vaddr - strtab_vaddr + len(name))

open(path, "wb").write(d)
print(f"addneeded: {needed} -> {path} (dynamic @ {hex(dyn_off)}, {len(new)} entries)")
