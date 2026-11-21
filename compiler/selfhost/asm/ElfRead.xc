// ElfRead.xc — the section table of a little-endian ELF32 or ELF64 file, read
// once for every reader in the compiler: objects and shared libraries for the
// links, debug files for DWARF, and the interface a library carries (#336).
//
// Every offset and size is read at its full width and checked in 64 bits, so
// an offset past 4 GB, or a sum that would wrap in 32 bits, is refused rather
// than cut down to a small number that points into the file. A file whose
// section table, section-name table or any section's bytes (other than a
// NOBITS one's) lie outside it is not read at all. What passes fits the
// file, whose length is a u32, so every value can be used as a u32.
#import "Foundation.xc"

class ElfSec
{
    String* _name;
    u32 _type;
    u64 _flags;
    u64 _addr;
    u64 _off;
    u64 _size;
    u32 _link;
    u32 _info;
    u64 _align;
    u64 _entsize;

    String* name(void)   { return _name; }
    u32 type(void)       { return _type; }
    u64 flags(void)      { return _flags; }
    u64 addr(void)       { return _addr; }
    u64 off(void)        { return _off; }
    u64 size(void)       { return _size; }
    u32 link(void)       { return _link; }
    u32 info(void)       { return _info; }
    u64 align(void)      { return _align; }
    u64 entsize(void)    { return _entsize; }
}

class ElfRead
{
    static u64 le(Data* d, u32 at, u32 n)
    {
        u64 v = (u64)0;
        for (u32 i = n; i > (u32)0; i = i - (u32)1)
            v = (v << (u64)8) | (u64)d.byteAt(at + i - (u32)1);
        return v;
    }

    // 1 for ELF32, 2 for ELF64, 0 for anything this does not read (not ELF,
    // or not little-endian).
    static u8 elfClass(Data* d)
    {
        if (d == (Data*)0 || d.length() < (u32)52)
            return (u8)0;
        if (d.byteAt((u32)0) != (u8)$7F || d.byteAt((u32)1) != (u8)'E' || d.byteAt((u32)2) != (u8)'L' || d.byteAt((u32)3) != (u8)'F')
            return (u8)0;
        if (d.byteAt((u32)5) != (u8)1)
            return (u8)0;
        u8 c = d.byteAt((u32)4);
        if (c == (u8)2 && d.length() < (u32)64)
            return (u8)0;
        return c == (u8)1 || c == (u8)2 ? c : (u8)0;
    }

    // [off, off + size) inside a file of `len` bytes, without wrapping.
    static bool fits(u64 off, u64 size, u64 len)
    {
        return off <= len && size <= len - off;
    }

    // The sections, in table order (index 0 is the null section), or null
    // when the file is not a little-endian ELF this reads or its table does
    // not fit it.
    static Array* sections(Data* d)
    {
        u8 cls = ElfRead.elfClass(d);
        if (cls == (u8)0)
            return (Array*)0;
        bool e32 = cls == (u8)1;
        u64 len = (u64)d.length();
        u64 shoff = e32 ? ElfRead.le(d, (u32)32, (u32)4) : ElfRead.le(d, (u32)40, (u32)8);
        u64 shent = ElfRead.le(d, e32 ? (u32)46 : (u32)58, (u32)2);
        u64 shnum = ElfRead.le(d, e32 ? (u32)48 : (u32)60, (u32)2);
        u64 shstr = ElfRead.le(d, e32 ? (u32)50 : (u32)62, (u32)2);
        u64 minEnt = e32 ? (u64)40 : (u64)64;
        if (shoff == (u64)0 || shnum == (u64)0 || shent < minEnt)
            return (Array*)0;
        if (!ElfRead.fits(shoff, shnum * shent, len) || shstr >= shnum)
            return (Array*)0;
        Array* out = new Array();
        for (u64 i = (u64)0; i < shnum; i = i + (u64)1)
        {
            u32 h = (u32)(shoff + i * shent);
            ElfSec* s = new ElfSec();
            s._name = (String*)0;
            s._type = (u32)ElfRead.le(d, h + (u32)4, (u32)4);
            if (e32)
            {
                s._flags = ElfRead.le(d, h + (u32)8, (u32)4);
                s._addr = ElfRead.le(d, h + (u32)12, (u32)4);
                s._off = ElfRead.le(d, h + (u32)16, (u32)4);
                s._size = ElfRead.le(d, h + (u32)20, (u32)4);
                s._link = (u32)ElfRead.le(d, h + (u32)24, (u32)4);
                s._info = (u32)ElfRead.le(d, h + (u32)28, (u32)4);
                s._align = ElfRead.le(d, h + (u32)32, (u32)4);
                s._entsize = ElfRead.le(d, h + (u32)36, (u32)4);
            }
            else
            {
                s._flags = ElfRead.le(d, h + (u32)8, (u32)8);
                s._addr = ElfRead.le(d, h + (u32)16, (u32)8);
                s._off = ElfRead.le(d, h + (u32)24, (u32)8);
                s._size = ElfRead.le(d, h + (u32)32, (u32)8);
                s._link = (u32)ElfRead.le(d, h + (u32)40, (u32)4);
                s._info = (u32)ElfRead.le(d, h + (u32)44, (u32)4);
                s._align = ElfRead.le(d, h + (u32)48, (u32)8);
                s._entsize = ElfRead.le(d, h + (u32)56, (u32)8);
            }
            // A NOBITS section (.bss) has a size but no bytes in the file.
            if (s._type != (u32)8 && !ElfRead.fits(s._off, s._size, len))
                return (Array*)0;
            out.add((Object*)s);
        }
        // The names, through the section-name table, each ending inside it.
        ElfSec* st = (ElfSec*)out.get((u32)shstr);
        u32 sOff = (u32)st._off;
        u32 sEnd = (u32)(st._off + st._size);
        for (u64 i = (u64)0; i < shnum; i = i + (u64)1)
        {
            u32 h = (u32)(shoff + i * shent);
            u64 nameAt = (u64)sOff + ElfRead.le(d, h, (u32)4);
            String* nm = new String();
            for (u64 k = nameAt; k < (u64)sEnd && d.byteAt((u32)k) != (u8)0; k = k + (u64)1)
                nm.appendByte(d.byteAt((u32)k));
            ((ElfSec*)out.get((u32)i))._name = nm;
        }
        return out;
    }
}
