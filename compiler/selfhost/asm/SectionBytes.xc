// SectionBytes.xc — a section's contents: bytes, then a run of zeros.
// =================================================================
//
// What the assemblers, linkers and image writers hold a section in. The bytes
// that have been written are kept in a Data; a run of zero bytes at the END is
// only counted. So zero-filled space — a `.bss` section, `.zero`/`.space`,
// `.comm`/`.lcomm`/`.zerofill` storage, alignment padding — costs nothing
// until something non-zero is written after it, and a writer that leaves a
// trailing zero run out of its file (p_memsz > p_filesz, a NOBITS section)
// never allocates it at all.
//
// To a reader the run is ordinary content: length() counts it and byteAt()
// reads it as zero. Writing a non-zero byte into it, or appending after it,
// stores the zeros up to that point first, so every offset means what it
// meant before. It changes how a section is held, never what it holds.

#import "Foundation.xc"

class SectionBytes
    {
    Data* _stored; // bytes [0, _stored.length())
    u32 _zeros;    // then this many zero bytes, counted but not allocated

    void init(void)
        {
        _stored = new Data();
        _zeros = (u32)0;
        }

    static SectionBytes* withData(Data* d)
        {
        SectionBytes* s = new SectionBytes();
        if (d != (Data*)0)
            s._stored.append(d);
        return s;
        }

    // A copy, sharing nothing with this one.
    SectionBytes* copy(void)
        {
        SectionBytes* s = new SectionBytes();
        s._stored.append(_stored);
        s._zeros = _zeros;
        return s;
        }

    // Take `o`'s contents in place, so whoever holds this one sees them.
    void setContents(SectionBytes* o)
        {
        _stored = new Data();
        _stored.append(o._stored);
        _zeros = o._zeros;
        }

    u32 length(void)
        {
        return _stored.length() + _zeros;
        }

    // The bytes held; everything past them up to length() is zero.
    u32 storedLength(void)
        {
        return _stored.length();
        }
    Data* stored(void)
        {
        return _stored;
        }

    // The length without its trailing zero run: what an image writer stores
    // in the file when the loader zero-fills the rest.
    u32 fileLength(void)
        {
        u32 n = _stored.length();
        u8* b = _stored.bytes();
        while (n > (u32)0 && b[n - (u32)1] == (u8)0)
            n = n - (u32)1;
        return n;
        }

    u8 byteAt(u32 i)
        {
        if (i < _stored.length())
            return _stored.byteAt(i);
        return (u8)0;
        }

    void setByteAt(u32 i, u8 v)
        {
        if (i >= _stored.length())
            {
            if (v == (u8)0)
                return;
            materialise(i + (u32)1);
            }
        _stored.setByteAt(i, v);
        }

    void appendByte(u8 b)
        {
        if (b == (u8)0)
            {
            _zeros = _zeros + (u32)1;
            return;
            }
        flush();
        _stored.appendByte(b);
        }

    void appendZeros(u32 n)
        {
        _zeros = _zeros + n;
        }

    // Zero bytes until the length is a multiple of `al`.
    void padTo(u32 al)
        {
        if (al <= (u32)1)
            return;
        u32 r = length() % al;
        if (r != (u32)0)
            _zeros = _zeros + (al - r);
        }

    // The low `n` bytes of `v`, least significant first.
    void appendLE(u32 v, u32 n)
        {
        for (u32 k = (u32)0; k < n; k = k + (u32)1)
            appendByte(k < (u32)4 ? (u8)((v >> ((u32)8 * k)) & (u32)$FF) : (u8)0);
        }

    void append(SectionBytes* o)
        {
        if (o == (SectionBytes*)0)
            return;
        if (o._stored.length() > (u32)0)
            {
            flush();
            _stored.append(o._stored);
            }
        _zeros = _zeros + o._zeros;
        }

    void appendData(Data* d)
        {
        if (d == (Data*)0 || d.length() == (u32)0)
            return;
        flush();
        _stored.append(d);
        }

    // Bytes [from, from + n), clamped to the length.
    SectionBytes* subrange(u32 from, u32 n)
        {
        SectionBytes* s = new SectionBytes();
        u32 len = length();
        if (from >= len)
            return s;
        if (n > len - from)
            n = len - from;
        u32 sl = _stored.length();
        if (from < sl)
            {
            u32 k = sl - from < n ? sl - from : n;
            u8* b = _stored.bytes();
            s._stored.appendBytes(&b[from], k);
            s._zeros = n - k;
            }
        else
            s._zeros = n;
        return s;
        }

    // Store the zero run up to length `n`.
    void materialise(u32 n)
        {
        u32 sl = _stored.length();
        if (n <= sl)
            return;
        u32 k = n - sl;
        if (k > _zeros)
            k = _zeros;
        _stored.increaseLengthBy(k);
        _zeros = _zeros - k;
        }

    void flush(void)
        {
        if (_zeros == (u32)0)
            return;
        _stored.increaseLengthBy(_zeros);
        _zeros = (u32)0;
        }

    // Every byte, as one Data. For a consumer that stores all of them anyway
    // (an object file's data section).
    Data* toData(void)
        {
        Data* d = Data.withCapacity(length());
        d.append(_stored);
        d.increaseLengthBy(_zeros);
        return d;
        }

    // Bytes [from, from + n) onto `out`.
    void appendRangeTo(Data* out, u32 from, u32 n)
        {
        u32 sl = _stored.length();
        u32 k = (u32)0;
        if (from < sl)
            {
            k = sl - from < n ? sl - from : n;
            u8* b = _stored.bytes();
            out.appendBytes(&b[from], k);
            }
        if (n > k)
            out.increaseLengthBy(n - k);
        }
    }
