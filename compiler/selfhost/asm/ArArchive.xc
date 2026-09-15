// ArArchive.xc — the `ar` container.
// =================================================================
//
// `!<arch>\n`, then 60-byte headers each followed by its member, padded to an
// even length. The one thing Mach-O, ELF and COFF static libraries share, so
// it is one file with no target in it.
//
// Three name conventions, all of which appear in archives we have to read:
//
//   `//`          the long-name member; a header then names one as `/<offset>`
//   `name/`       COFF's short form — the name with the slash stripped
//   `#1/<len>`    BSD/Mach-O — the name is the first <len> bytes of the BODY,
//                 so it comes off the front of the DATA, not just the header
//
// `/` (the symbol index) and `__.SYMDEF` are skipped: a member selection driven
// by the index would be faster, but scanning the members is correct without it
// and cannot disagree with them.
//
// Ported from the reference's XTArArchive so the port can link against a real
// libc (task #47). Verified against musl's libc.a, which uses the `//` form.
#import "Foundation.xc"
#import "Files.xc"

class ArMember
    {
    String* _name;
    Data* _data;
    void init(void)
        {
        }
    String* name(void)
        {
        return _name;
        }
    Data* data(void)
        {
        return _data;
        }
    void setName(String* n)
        {
        _name = n;
        }
    void setData(Data* d)
        {
        _data = d;
        }
    }

    class ArArchive
    {
    u8 unused;
    void init(void)
        {
        }

    static bool isArchive(Data* d)
        {
        if (d == 0 || d.length() < (u32)8)
            return false;
        return d.byteAt((u32)0) == (u8)'!' && d.byteAt((u32)1) == (u8)'<' && d.byteAt((u32)2) == (u8)'a' && d.byteAt((u32)3) == (u8)'r' && d.byteAt((u32)4) == (u8)'c' && d.byteAt((u32)5) == (u8)'h' && d.byteAt((u32)6) == (u8)'>' && d.byteAt((u32)7) == (u8)10;
        }

    // Every member, in archive order. 0 when this is not an archive.
    static Array* members(Data* d)
        {
        if (!ArArchive.isArchive(d))
            return (Array*)0;
        Array* out = new Array();
        Data* longNames = (Data*)0;
        u32 p = (u32)8;
        while (p + (u32)60 <= d.length())
            {
            String* nm = ArArchive._field(d, p, (u32)16).trimmed();
            u32 msize = (u32)ArArchive._decimal(ArArchive._field(d, p + (u32)48, (u32)10));
            u32 body = p + (u32)60;
            if (body + msize > d.length())
                break;

            if (nm.equals(String.withCString("//")))
                {
                longNames = ArArchive._slice(d, body, msize);
                }
            else if (nm.byteLength() > (u32)1 && nm.byteAt((u32)0) == (u8)'/' && longNames != 0)
                {
                u32 at = (u32)ArArchive._decimal(nm.substringFromByte((u32)1));
                if (at < longNames.length())
                    {
                    u32 e = at;
                    while (e < longNames.length() && longNames.byteAt(e) != (u8)'/' && longNames.byteAt(e) != (u8)10)
                        e = e + (u32)1;
                    nm = ArArchive._text(longNames, at, e - at);
                    }
                }
            else if (nm.byteLength() > (u32)1 && nm.byteAt(nm.byteLength() - (u32)1) == (u8)'/')
                {
                nm = nm.substringBytes((u32)0, nm.byteLength() - (u32)1);
                }

            // BSD long name: the first `extra` bytes of the body ARE the name.
            u32 extra = (u32)0;
            if (nm.hasPrefix(String.withCString("#1/")))
                {
                extra = (u32)ArArchive._decimal(nm.substringFromByte((u32)3));
                if (extra > msize)
                    break;
                nm = ArArchive._text(d, body, extra).trimmed();
                }

            bool skip = nm.equals(String.withCString("/")) || nm.equals(String.withCString("//")) || nm.hasPrefix(String.withCString("__.SYMDEF"));
            if (!skip && msize > extra)
                {
                ArMember* m = new ArMember();
                m.setName(nm);
                m.setData(ArArchive._slice(d, body + extra, msize - extra));
                out.add((Object*)m);
                }
            p = body + msize + (msize & (u32)1); // members are even-padded
            }
        return out;
        }

    static Array* membersOfFile(String* path)
        {
        Data* d = Files.readData(path);
        if (d == 0)
            return (Array*)0;
        return ArArchive.members(d);
        }

    // ── the small readers ────────────────────────────────────────────────
    static String* _field(Data* d, u32 off, u32 len)
        {
        return ArArchive._text(d, off, len);
        }

    static String* _text(Data* d, u32 off, u32 len)
        {
        String* s = String.withCString("");
        for (u32 i = (u32)0; i < len && off + i < d.length(); i = i + (u32)1)
            {
            u8 c = d.byteAt(off + i);
            if (c == (u8)0)
                break;
            s.appendByte(c);
            }
        return s;
        }

    // Leading decimal digits; stops at the first non-digit, as atoll does.
    static u32 _decimal(String* s)
        {
        u32 v = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)32)
                continue;
            if (c < (u8)'0' || c > (u8)'9')
                break;
            v = v * (u32)10 + (u32)(c - (u8)'0');
            }
        return v;
        }

    static Data* _slice(Data* d, u32 off, u32 len)
        {
        Data* out = Data.withCapacity(len);
        for (u32 i = (u32)0; i < len && off + i < d.length(); i = i + (u32)1)
            out.appendByte(d.byteAt(off + i));
        return out;
        }
    }
