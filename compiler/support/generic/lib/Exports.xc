// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

// Exports.xc — the names a shared library exports, read from its bytes
// without loading it (bundles-and-plugins.md §4 step 5: a plugin's code is
// checked against its manifest before any of it runs, since loading runs its
// constructors).
//
//     Array* names = Exports.of(Files.readData(path));   // 0: not a library this reads
//
// Mach-O 64 (the LC_SYMTAB's external defined symbols, the leading '_'
// dropped), ELF64 (.dynsym, or through the dynamic segment when the section
// table does not name it) and PE32+ (the export directory's names). Every
// offset is checked against the file, so a hostile file gives 0, not a fault.
#import "Foundation.xc"

class Exports : Object
    {
    Data* _d;
    bool _bad;

    u64 _u(u32 at, u32 n)
        {
        if (_bad || (u64)at + (u64)n > (u64)_d.length())
            {
            _bad = true;
            return (u64)0;
            }
        u8* b = _d.bytes();
        u64 v = (u64)0;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            v = v | ((u64)b[at + i] << ((u64)i * (u64)8));
        return v;
        }

    u32 _u32(u64 at) { return at > (u64)0xFFFFFFF0 ? (u32)self._fail() : (u32)self._u((u32)at, (u32)4); }
    u32 _u16(u64 at) { return at > (u64)0xFFFFFFF0 ? (u32)self._fail() : (u32)self._u((u32)at, (u32)2); }
    u64 _u64(u64 at) { return at > (u64)0xFFFFFFF0 ? self._fail() : self._u((u32)at, (u32)8); }
    u32 _u8(u64 at) { return at > (u64)0xFFFFFFF0 ? (u32)self._fail() : (u32)self._u((u32)at, (u32)1); }

    u64 _fail(void)
        {
        _bad = true;
        return (u64)0;
        }

    // The NUL-terminated string at, within the file and at most 4096 bytes.
    String* _str(u64 at)
        {
        if (at >= (u64)_d.length())
            {
            _bad = true;
            return (String*)0;
            }
        u8* b = _d.bytes();
        u32 e = (u32)at;
        while (e < _d.length() && b[e] != (u8)0 && e - (u32)at < (u32)4096)
            e = e + (u32)1;
        if (e >= _d.length() || b[e] != (u8)0)
            {
            _bad = true;
            return (String*)0;
            }
        return String.withBytes(&b[(u32)at], e - (u32)at);
        }

    static Array* of(Data* d)
        {
        if (d == (Data*)0 || d.length() < (u32)64)
            return (Array*)0;
        Exports* x = new Exports();
        x._d = d;
        Array* r = (Array*)0;
        u32 magic = x._u32((u64)0);
        if (magic == (u32)0xFEEDFACF)
            r = x._macho();
        else if (magic == (u32)0x464C457F && x._u8((u64)4) == (u32)2)
            r = x._elf();
        else if (x._u16((u64)0) == (u32)0x5A4D)
            r = x._pe();
        return x._bad ? (Array*)0 : r;
        }

    Array* _macho(void)
        {
        Array* r = new Array();
        u32 ncmds = self._u32((u64)16);
        u64 at = (u64)32;
        for (u32 i = (u32)0; i < ncmds && !_bad; i = i + (u32)1)
            {
            u32 cmd = self._u32(at);
            u32 size = self._u32(at + (u64)4);
            if (size < (u32)8)
                return (Array*)self._fail();
            if (cmd == (u32)2)
                {
                u64 symoff = (u64)self._u32(at + (u64)8);
                u32 nsyms = self._u32(at + (u64)12);
                u64 stroff = (u64)self._u32(at + (u64)16);
                for (u32 k = (u32)0; k < nsyms && !_bad; k = k + (u32)1)
                    {
                    u64 e = symoff + (u64)k * (u64)16;
                    u32 type = self._u8(e + (u64)4);
                    if ((type & (u32)1) == (u32)0 || (type & (u32)0x0E) != (u32)0x0E)
                        continue;
                    String* n = self._str(stroff + (u64)self._u32(e));
                    if (n == (String*)0)
                        break;
                    if (n.byteLength() > (u32)0 && n.byteAt((u32)0) == (u8)'_')
                        n = n.substringFromByte((u32)1);
                    r.add((Object*)n);
                    }
                }
            at = at + (u64)size;
            }
        return r;
        }

    // A virtual address in the file, through the PT_LOAD that maps it.
    u64 _elfOffset(u64 va)
        {
        u64 phoff = self._u64((u64)0x20);
        u32 phent = self._u16((u64)0x36);
        u32 phnum = self._u16((u64)0x38);
        for (u32 i = (u32)0; i < phnum && !_bad; i = i + (u32)1)
            {
            u64 p = phoff + (u64)i * (u64)phent;
            if (self._u32(p) != (u32)1)
                continue;
            u64 off = self._u64(p + (u64)8);
            u64 vaddr = self._u64(p + (u64)16);
            u64 filesz = self._u64(p + (u64)32);
            if (va >= vaddr && va < vaddr + filesz)
                return off + (va - vaddr);
            }
        return self._fail();
        }

    void _elfSyms(Array* r, u64 symoff, u64 count, u64 stroff)
        {
        for (u64 k = (u64)1; k < count && !_bad; k = k + (u64)1)
            {
            u64 e = symoff + k * (u64)24;
            u32 bind = self._u8(e + (u64)4) >> (u32)4;
            u32 shndx = self._u16(e + (u64)6);
            if (shndx == (u32)0 || (bind != (u32)1 && bind != (u32)2))
                continue;
            String* n = self._str(stroff + (u64)self._u32(e));
            if (n == (String*)0)
                return;
            r.add((Object*)n);
            }
        }

    Array* _elf(void)
        {
        Array* r = new Array();
        u64 shoff = self._u64((u64)0x28);
        u32 shent = self._u16((u64)0x3A);
        u32 shnum = self._u16((u64)0x3C);
        for (u32 i = (u32)0; shoff != (u64)0 && i < shnum && !_bad; i = i + (u32)1)
            {
            u64 s = shoff + (u64)i * (u64)shent;
            if (self._u32(s + (u64)4) != (u32)11)
                continue;
            u64 off = self._u64(s + (u64)24);
            u64 size = self._u64(s + (u64)32);
            u32 link = self._u32(s + (u64)40);
            u64 strs = self._u64(shoff + (u64)link * (u64)shent + (u64)24);
            self._elfSyms(r, off, size / (u64)24, strs);
            return r;
            }
        // No .dynsym section: the dynamic segment's DT_SYMTAB, DT_STRTAB and
        // DT_HASH (whose second word is the symbol count).
        u64 phoff = self._u64((u64)0x20);
        u32 phent = self._u16((u64)0x36);
        u32 phnum = self._u16((u64)0x38);
        for (u32 i = (u32)0; i < phnum && !_bad; i = i + (u32)1)
            {
            u64 p = phoff + (u64)i * (u64)phent;
            if (self._u32(p) != (u32)2)
                continue;
            u64 dyn = self._u64(p + (u64)8);
            u64 dsz = self._u64(p + (u64)32);
            u64 sym = (u64)0;
            u64 str = (u64)0;
            u64 hash = (u64)0;
            for (u64 at = dyn; at + (u64)16 <= dyn + dsz && !_bad; at = at + (u64)16)
                {
                u64 tag = self._u64(at);
                u64 val = self._u64(at + (u64)8);
                if (tag == (u64)0)
                    break;
                if (tag == (u64)6) sym = val;
                if (tag == (u64)5) str = val;
                if (tag == (u64)4) hash = val;
                }
            if (sym == (u64)0 || str == (u64)0 || hash == (u64)0)
                return (Array*)self._fail();
            u64 count = (u64)self._u32(self._elfOffset(hash) + (u64)4);
            self._elfSyms(r, self._elfOffset(sym), count, self._elfOffset(str));
            return r;
            }
        return (Array*)self._fail();
        }

    // A PE relative virtual address in the file, through its section.
    u64 _peOffset(u64 sections, u32 nsec, u32 rva)
        {
        for (u32 i = (u32)0; i < nsec && !_bad; i = i + (u32)1)
            {
            u64 s = sections + (u64)i * (u64)40;
            u32 vsize = self._u32(s + (u64)8);
            u32 va = self._u32(s + (u64)12);
            u32 raw = self._u32(s + (u64)16);
            u32 ptr = self._u32(s + (u64)20);
            u32 span = vsize > raw ? vsize : raw;
            if (rva >= va && rva < va + span)
                return (u64)ptr + (u64)(rva - va);
            }
        return self._fail();
        }

    Array* _pe(void)
        {
        Array* r = new Array();
        u64 pe = (u64)self._u32((u64)0x3C);
        if (self._u32(pe) != (u32)0x00004550)
            return (Array*)self._fail();
        u32 nsec = self._u16(pe + (u64)6);
        u32 optSize = self._u16(pe + (u64)20);
        u64 opt = pe + (u64)24;
        if (self._u16(opt) != (u32)0x20B)
            return (Array*)self._fail();
        u32 expRva = self._u32(opt + (u64)112);
        u64 sections = opt + (u64)optSize;
        if (expRva == (u32)0)
            return r;
        u64 ex = self._peOffset(sections, nsec, expRva);
        u32 n = self._u32(ex + (u64)24);
        u64 names = self._peOffset(sections, nsec, self._u32(ex + (u64)32));
        for (u32 i = (u32)0; i < n && !_bad; i = i + (u32)1)
            {
            String* s = self._str(self._peOffset(sections, nsec, self._u32(names + (u64)i * (u64)4)));
            if (s == (String*)0)
                break;
            r.add((Object*)s);
            }
        return r;
        }
    }
