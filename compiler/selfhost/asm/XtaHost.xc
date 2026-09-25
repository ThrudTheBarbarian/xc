// XtaHost.xc — what the xcc-as command line needs from the host: path
// arithmetic, directory listings, the text of a file-open failure, and the
// banking half of a `.lnk` layout.
// =================================================================
//
// The path rules are the ones the reference tool inherits from its string
// library: `a//b.asm/` is `a/b.asm`, an extension is what follows the last dot
// of the last component unless that dot opens the name or the extension holds
// a space, and `x.` has none. The default output name depends on all three.

#import "Foundation.xc"
#import "Files.xc"
#import "Xta.xc"

#if ARCH_win64
pointer FindFirstFileA(u8* pattern, u8* data);
i32 FindNextFileA(pointer h, u8* data);
i32 FindClose(pointer h);
#else
#if ARCH_x86_64
i64 _sys_open(u8* path, i64 flags, i64 mode);
i64 _sys_getdents64(i64 fd, u8* buf, i64 count);
i64 _sys_close(i64 fd);
#else
// macOS: the 64-bit-inode dirent, whose name starts at byte 21.
pointer opendir(u8* path);
pointer readdir(pointer d);
i32 closedir(pointer d);
#endif
#endif

class XaDir
    {
    u8 _unused;

    void init(void)
        {
        _unused = (u8)0;
        }

    // The names in a directory, without `.` and `..`; null when it cannot be
    // opened as one.
    static Array* list(String* path)
        {
        Array* out = new Array();
#if ARCH_win64
        String* pattern = String.withString(path);
        pattern.appendCString("\\*");
        u8* data = new u8[(u32)592];
        pointer h = FindFirstFileA(pattern.cString(), data);
        if ((i64)h == (i64)-1 || h == (pointer)0)
            return (Array*)0;
        while (true)
            {
            String* name = String.withCString(data + 44);
            XaDir.addName(out, name);
            if (FindNextFileA(h, data) == (i32)0)
                break;
            }
        FindClose(h);
        return out;
#else
#if ARCH_x86_64
        // O_RDONLY | O_DIRECTORY | O_CLOEXEC
        i64 fd = _sys_open(path.cString(), (i64)$90000, (i64)0);
        if (fd < (i64)0)
            return (Array*)0;
        u8* buf = new u8[(u32)8192];
        while (true)
            {
            i64 got = _sys_getdents64(fd, buf, (i64)8192);
            if (got <= (i64)0)
                break;
            i64 off = (i64)0;
            while (off < got)
                {
                u8* ent = buf + (u32)off;
                u32 reclen = (u32)ent[16] | ((u32)ent[17] << (u32)8);
                XaDir.addName(out, String.withCString(ent + 19));
                if (reclen == (u32)0)
                    break;
                off = off + (i64)reclen;
                }
            }
        _sys_close(fd);
        return out;
#else
        pointer d = opendir(path.cString());
        if (d == (pointer)0)
            return (Array*)0;
        while (true)
            {
            pointer e = readdir(d);
            if (e == (pointer)0)
                break;
            XaDir.addName(out, String.withCString((u8*)e + 21));
            }
        closedir(d);
        return out;
#endif
#endif
        }

    static void addName(Array* out, String* name)
        {
        if (name.equals(String.withCString(".")) || name.equals(String.withCString("..")))
            return;
        out.add((Object*)name);
        }

    static bool isDirectory(String* path)
        {
        return XaDir.list(path) != (Array*)0;
        }

    // Byte order, which is the reference's order for these names.
    static void sort(Array* a)
        {
        for (u32 i = (u32)1; i < a.count(); i = i + (u32)1)
            {
            Object* v = a.get(i);
            u32 j = i;
            while (j > (u32)0 && ((String*)a.get(j - (u32)1)).compare((String*)v) > (i8)0)
                {
                a.set(j, a.get(j - (u32)1));
                j = j - (u32)1;
                }
            a.set(j, v);
            }
        }
    }

class XaPath
    {
    u8 _unused;

    void init(void)
        {
        _unused = (u8)0;
        }

    // Repeated slashes collapse and a trailing one goes, except for the root.
    static String* standard(String* p)
        {
        String* o = new String();
        for (u32 i = (u32)0; i < p.byteLength(); i = i + (u32)1)
            {
            u8 c = p.byteAt(i);
            if (c == (u8)'/' && o.byteLength() > (u32)0 && o.byteAt(o.byteLength() - (u32)1) == (u8)'/')
                continue;
            o.appendByte(c);
            }
        if (o.byteLength() > (u32)1 && o.byteAt(o.byteLength() - (u32)1) == (u8)'/')
            return o.substringBytes((u32)0, o.byteLength() - (u32)1);
        return o;
        }

    static String* lastComponent(String* p)
        {
        String* s = XaPath.standard(p);
        if (s.equals(String.withCString("/")))
            return s;
        u32 slash = s.lastIndexOfByte((u8)'/');
        return slash == (u32)$FFFF_FFFF ? s : s.substringFromByte(slash + (u32)1);
        }

    static String* deletingLastComponent(String* p)
        {
        String* s = XaPath.standard(p);
        u32 slash = s.lastIndexOfByte((u8)'/');
        if (slash == (u32)$FFFF_FFFF)
            return String.withCString("");
        if (slash == (u32)0)
            return String.withCString("/");
        return s.substringBytes((u32)0, slash);
        }

    static String* appending(String* base, String* comp)
        {
        if (base.byteLength() == (u32)0)
            return XaPath.standard(comp);
        String* s = String.withString(base);
        s.appendCString("/");
        s.append(comp);
        return XaPath.standard(s);
        }

    // The extension of the last component, or "" when it has none.
    static String* extension(String* p)
        {
        String* comp = XaPath.lastComponent(p);
        u32 dot = comp.lastIndexOfByte((u8)'.');
        if (dot == (u32)$FFFF_FFFF || dot == (u32)0)
            return String.withCString("");
        String* ext = comp.substringFromByte(dot + (u32)1);
        if (ext.byteLength() == (u32)0 || ext.indexOfByte((u8)' ') != (u32)$FFFF_FFFF)
            return String.withCString("");
        return ext;
        }

    static String* deletingExtension(String* p)
        {
        String* s = XaPath.standard(p);
        String* ext = XaPath.extension(s);
        if (ext.byteLength() == (u32)0)
            return s;
        return s.substringBytes((u32)0, s.byteLength() - ext.byteLength() - (u32)1);
        }

    // Null where the reference refuses (an empty path, or the root).
    static String* appendingExtension(String* p, String* ext)
        {
        if (p.byteLength() == (u32)0 || p.equals(String.withCString("/")))
            return (String*)0;
        String* s = String.withString(p);
        s.appendCString(".");
        s.append(ext);
        return s;
        }

    // The text of a file that cannot be read, in the words a user of the
    // reference has seen: missing, a directory, unreadable, not UTF-8.
    // Null when the file reads as text.
    static String* readFailure(String* path, String* text)
        {
        String* name = XaPath.lastComponent(path);
        String* m = String.withCString("The file “");
        m.append(name);
        if (!Files.exists(path))
            {
            m.appendCString("” couldn’t be opened because there is no such file.");
            return m;
            }
        if (XaDir.isDirectory(path))
            {
            m.appendCString("” couldn’t be opened.");
            return m;
            }
        if (text == (String*)0)
            {
            m.appendCString("” couldn’t be opened because you don’t have permission to view it.");
            return m;
            }
        if (!XaText.isUtf8(text))
            {
            m.appendCString("” couldn’t be opened using text encoding Unicode (UTF-8).");
            return m;
            }
        return (String*)0;
        }
    }

// The banking view of a `.lnk` layout, as the assembler reads it: the bank
// windows and registers, split banking, region C, and the main region. Every
// other section is parsed only as far as its errors, because an error anywhere
// in the file refuses the whole layout.
class XaLayout
    {
    String* _error;
    bool _hasBanking;
    u32 _bankWindowStart;
    u32 _bankWindowEnd;
    Array* _mainRanges; // pairs of Number@, or null
    bool _hasSplitBanking;
    u32 _codeWindowStart;
    u32 _codeWindowEnd;
    u32 _dataWindowStart;
    u32 _dataWindowEnd;
    u32 _codeBankReg;
    u32 _dataBankReg;
    bool _hasRegionC;
    u32 _regCWindowStart;
    u32 _regCWindowEnd;
    u32 _regCPageSize;
    u32 _regCBankRegLo;
    u32 _regCBankRegHi;
    // The [cloaked] block being read, and the ids committed so far.
    bool _pending;
    i32 _pendingBank;
    i32 _pendingBankEnd;
    String* _pendingId;
    Array* _cloakedIds;

    void init(void)
        {
        _cloakedIds = new Array();
        _pending = false;
        }

    String* error(void)
        {
        return _error;
        }
    bool hasBanking(void)
        {
        return _hasBanking;
        }
    u32 bankWindowStart(void)
        {
        return _bankWindowStart;
        }
    u32 bankWindowEnd(void)
        {
        return _bankWindowEnd;
        }
    Array* mainRanges(void)
        {
        return _mainRanges;
        }
    bool hasSplitBanking(void)
        {
        return _hasSplitBanking;
        }
    u32 dataWindowStart(void)
        {
        return _dataWindowStart;
        }
    u32 dataWindowEnd(void)
        {
        return _dataWindowEnd;
        }
    u32 codeBankReg(void)
        {
        return _codeBankReg;
        }
    u32 dataBankReg(void)
        {
        return _dataBankReg;
        }
    bool hasRegionC(void)
        {
        return _hasRegionC;
        }
    u32 regCWindowStart(void)
        {
        return _regCWindowStart;
        }
    u32 regCWindowEnd(void)
        {
        return _regCWindowEnd;
        }
    u32 regCBankRegLo(void)
        {
        return _regCBankRegLo;
        }
    u32 regCBankRegHi(void)
        {
        return _regCBankRegHi;
        }

    XaLayout* fail(String* m)
        {
        _error = m;
        return self;
        }

    // ── Values ───────────────────────────────────────────────────────────
    //
    // `$hex` or a decimal, the whole value, truncated to 16 bits.
    static bool hexOrDec(String* s0, u32* out)
        {
        String* s = XaText.tws(s0);
        if (s.hasPrefix(String.withCString("$")))
            {
            u32 v = (u32)0;
            u32 end = (u32)0;
            String* rest = s.substringFromByte((u32)1);
            if (!XaText.scanHex(rest, &v, &end) || !XaText.restIsWs(rest, end))
                return false;
            *out = v & (u32)$FFFF;
            return true;
            }
        // scanInt: white space, a sign, digits; saturates at the int range.
        u32 n = s.byteLength();
        u32 i = (u32)0;
        while (i < n && XaText.isWsNl(s.byteAt(i)))
            i = i + (u32)1;
        bool neg = false;
        if (i < n && (s.byteAt(i) == (u8)'+' || s.byteAt(i) == (u8)'-'))
            {
            neg = s.byteAt(i) == (u8)'-';
            i = i + (u32)1;
            }
        u32 start = i;
        i64 v = (i64)0;
        while (i < n && s.byteAt(i) >= (u8)'0' && s.byteAt(i) <= (u8)'9')
            {
            if (v < (i64)$8000_0000)
                v = v * (i64)10 + (i64)(s.byteAt(i) - (u8)'0');
            i = i + (u32)1;
            }
        if (i == start || !XaText.restIsWs(s, i))
            return false;
        if (neg)
            v = (i64)0 - v;
        if (v > (i64)$7FFF_FFFF)
            v = (i64)$7FFF_FFFF;
        if (v < (i64)-2147483648)
            v = (i64)-2147483648;
        *out = (u32)v & (u32)$FFFF;
        return true;
        }

    static bool isRegexSpace(u8 c)
        {
        return XaText.isWsNl(c);
        }

    // The first `$hex - $hex` in the text.
    static bool range(String* s, u32* lo, u32* hi)
        {
        u32 n = s.byteLength();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            if (s.byteAt(i) != (u8)'$')
                continue;
            u32 j = i + (u32)1;
            while (j < n && XaText.hexDigit(s.byteAt(j)) >= (i32)0)
                j = j + (u32)1;
            if (j == i + (u32)1)
                continue;
            u32 k = j;
            while (k < n && XaLayout.isRegexSpace(s.byteAt(k)))
                k = k + (u32)1;
            if (k >= n || s.byteAt(k) != (u8)'-')
                continue;
            k = k + (u32)1;
            while (k < n && XaLayout.isRegexSpace(s.byteAt(k)))
                k = k + (u32)1;
            if (k >= n || s.byteAt(k) != (u8)'$')
                continue;
            u32 m = k + (u32)1;
            while (m < n && XaText.hexDigit(s.byteAt(m)) >= (i32)0)
                m = m + (u32)1;
            if (m == k + (u32)1)
                continue;
            u32 a = (u32)0;
            u32 b = (u32)0;
            if (!XaLayout.hexOrDec(s.substringBytes(i, j - i), &a) || !XaLayout.hexOrDec(s.substringBytes(k, m - k), &b))
                return false;
            *lo = a;
            *hi = b;
            return true;
            }
        return false;
        }

    static Array* rangeList(String* s)
        {
        Array* out = new Array();
        Array* parts = s.splitOnByte((u8)',');
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
            {
            u32 lo = (u32)0;
            u32 hi = (u32)0;
            if (XaLayout.range((String*)parts.get(i), &lo, &hi))
                {
                out.add((Object*)Number.withU32(lo));
                out.add((Object*)Number.withU32(hi));
                }
            }
        return out;
        }

    // strtoull over the whole value, `$` for hex.
    static bool longAddr(String* s0)
        {
        String* s = XaText.tws(s0);
        u32 base = (u32)10;
        if (s.hasPrefix(String.withCString("$")))
            {
            s = s.substringFromByte((u32)1);
            base = (u32)16;
            }
        u32 n = s.byteLength();
        u32 i = (u32)0;
        while (i < n && XaText.isWsNl(s.byteAt(i)))
            i = i + (u32)1;
        if (i < n && (s.byteAt(i) == (u8)'+' || s.byteAt(i) == (u8)'-'))
            i = i + (u32)1;
        if (base == (u32)16 && i + (u32)2 < n && s.byteAt(i) == (u8)'0' && (s.byteAt(i + (u32)1) == (u8)'x' || s.byteAt(i + (u32)1) == (u8)'X') && XaText.hexDigit(s.byteAt(i + (u32)2)) >= (i32)0)
            i = i + (u32)2;
        u32 start = i;
        while (i < n)
            {
            i32 d = XaText.hexDigit(s.byteAt(i));
            if (d < (i32)0 || (u32)d >= base)
                break;
            i = i + (u32)1;
            }
        return i > start && i == n;
        }

    // ── Sections ─────────────────────────────────────────────────────────
    void banking(String* key, String* value)
        {
        _hasBanking = true;
        u32 lo = (u32)0;
        u32 hi = (u32)0;
        u32 v = (u32)0;
        if (key.hasSuffix(String.withCString("-window")))
            {
            String* name = key.substringBytes((u32)0, key.byteLength() - (u32)7);
            if (!XaLayout.range(value, &lo, &hi))
                return;
            if (name.equals(String.withCString("code")))
                {
                _bankWindowStart = lo;
                _bankWindowEnd = hi;
                }
            else if (name.equals(String.withCString("data")))
                {
                _dataWindowStart = lo;
                _dataWindowEnd = hi;
                }
            return;
            }
        if (key.hasSuffix(String.withCString("-reg")))
            {
            String* name = key.substringBytes((u32)0, key.byteLength() - (u32)4);
            if (!XaLayout.hexOrDec(value, &v))
                return;
            if (name.equals(String.withCString("code")))
                _codeBankReg = v;
            else if (name.equals(String.withCString("data")))
                _dataBankReg = v;
            return;
            }
        if (key.equals(String.withCString("window")))
            {
            if (XaLayout.range(value, &lo, &hi))
                {
                _bankWindowStart = lo;
                _bankWindowEnd = hi;
                }
            return;
            }
        if (key.equals(String.withCString("registers")))
            {
            // Plain 8-bit selectors (no `:mask`) name the code and data bank
            // registers, first and second.
            Array* addrs = new Array();
            Array* masks = new Array();
            Array* parts = value.splitOnByte((u8)',');
            for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
                {
                String* spec = XaText.tws((String*)parts.get(i));
                Array* am = spec.splitOnByte((u8)':');
                u32 a = (u32)0;
                u32 mask = (u32)$FF;
                if (am.count() == (u32)1)
                    {
                    if (!XaLayout.hexOrDec((String*)am.get((u32)0), &a))
                        continue;
                    }
                else if (am.count() == (u32)2)
                    {
                    if (!XaLayout.hexOrDec((String*)am.get((u32)0), &a) || !XaLayout.hexOrDec((String*)am.get((u32)1), &mask))
                        continue;
                    mask = mask & (u32)$FF;
                    }
                else
                    continue;
                addrs.add((Object*)Number.withU32(a));
                masks.add((Object*)Number.withU32(mask));
                }
            if (addrs.count() >= (u32)1 && ((Number*)masks.get((u32)0)).asU32() == (u32)$FF)
                _codeBankReg = ((Number*)addrs.get((u32)0)).asU32();
            if (addrs.count() >= (u32)2 && ((Number*)masks.get((u32)1)).asU32() == (u32)$FF)
                _dataBankReg = ((Number*)addrs.get((u32)1)).asU32();
            return;
            }
        if (key.equals(String.withCString("codewindow")))
            {
            if (XaLayout.range(value, &lo, &hi))
                {
                _hasSplitBanking = true;
                _codeWindowStart = lo;
                _codeWindowEnd = hi;
                if (_codeWindowStart != (u32)0)
                    _bankWindowStart = _codeWindowStart;
                if (_dataWindowEnd != (u32)0)
                    _bankWindowEnd = _dataWindowEnd;
                }
            return;
            }
        if (key.equals(String.withCString("datawindow")))
            {
            if (XaLayout.range(value, &lo, &hi))
                {
                _dataWindowStart = lo;
                _dataWindowEnd = hi;
                }
            return;
            }
        if (key.equals(String.withCString("codereg")))
            {
            if (XaLayout.hexOrDec(value, &v))
                _codeBankReg = v;
            return;
            }
        if (key.equals(String.withCString("datareg")))
            {
            if (XaLayout.hexOrDec(value, &v))
                _dataBankReg = v;
            return;
            }
        if (key.equals(String.withCString("regcwindow")))
            {
            if (XaLayout.range(value, &lo, &hi))
                {
                _hasRegionC = true;
                _regCWindowStart = lo;
                _regCWindowEnd = hi;
                }
            return;
            }
        if (key.equals(String.withCString("regcpagesize")))
            {
            if (XaLayout.hexOrDec(value, &v))
                {
                _hasRegionC = true;
                _regCPageSize = v;
                }
            return;
            }
        if (key.equals(String.withCString("regcreg")))
            {
            // `$84` for an 8-bit selector, `$84-$85` for a 16-bit pair.
            if (XaLayout.range(value, &lo, &hi))
                {
                _hasRegionC = true;
                _regCBankRegLo = lo;
                _regCBankRegHi = hi;
                }
            else if (XaLayout.hexOrDec(value, &v))
                {
                _hasRegionC = true;
                _regCBankRegLo = v;
                _regCBankRegHi = (u32)0;
                }
            return;
            }
        if (key.equals(String.withCString("regcregion")) || key.equals(String.withCString("regcregionspan")))
            {
            if (XaLayout.longAddr(value))
                _hasRegionC = true;
            return;
            }
        }

    void cloaked(String* key, String* value)
        {
        if (key.equals(String.withCString("bank")))
            {
            String* v = XaText.tws(value);
            if (v.lowercased().equals(String.withCString("none")))
                {
                _pendingBank = (i32)-1;
                _pendingBankEnd = (i32)-1;
                return;
                }
            u32 dash = v.indexOfByte((u8)'-');
            u32 a = (u32)0;
            u32 b = (u32)0;
            if (dash != (u32)$FFFF_FFFF)
                {
                if (XaLayout.hexOrDec(v.substringBytes((u32)0, dash), &a) && XaLayout.hexOrDec(v.substringFromByte(dash + (u32)1), &b) && b >= a)
                    {
                    _pendingBank = (i32)a;
                    _pendingBankEnd = (i32)b;
                    }
                }
            else if (XaLayout.hexOrDec(v, &a))
                {
                _pendingBank = (i32)a;
                _pendingBankEnd = (i32)a;
                }
            return;
            }
        if (key.equals(String.withCString("id")))
            _pendingId = XaText.tws(value);
        }

    // Commit the open [cloaked] block: a single bank, or one region per bank
    // of a range, named by the `<n>` in its id.
    bool commitCloaked(String* path)
        {
        if (!_pending)
            return true;
        _pending = false;
        String* ph = String.withCString("<n>");
        bool hasPh = _pendingId.byteIndexOf(ph) != (u32)$FFFF_FFFF;
        if (_pendingBankEnd <= _pendingBank)
            {
            if (hasPh)
                {
                String* m = String.withString(path);
                m.appendCString(": [cloaked] id '");
                m.append(_pendingId);
                m.appendCString("' contains '<n>' but bank is not a range — placeholder is only valid with `bank = N-M`");
                fail(m);
                return false;
                }
            _cloakedIds.add((Object*)_pendingId);
            return true;
            }
        if (!hasPh)
            {
            String* m = String.withString(path);
            m.appendCString(": [cloaked] bank = ");
            m.append(String.withI32(_pendingBank));
            m.appendCString("-");
            m.append(String.withI32(_pendingBankEnd));
            m.appendCString(" (range) needs '<n>' placeholder in id (e.g. `id = ext<n>`); got '");
            m.append(_pendingId);
            m.appendCString("'");
            fail(m);
            return false;
            }
        for (i32 b = _pendingBank; b <= _pendingBankEnd; b = b + (i32)1)
            {
            String* id = String.withString(_pendingId);
            id.replaceOccurrences(ph, String.withI32(b));
            _cloakedIds.add((Object*)id);
            }
        return true;
        }

    // Fields this layout leaves unset come from an included one.
    void mergeDefaults(XaLayout* b)
        {
        if (_mainRanges == (Array*)0)
            _mainRanges = b._mainRanges;
        if (!_hasBanking)
            _hasBanking = b._hasBanking;
        if (_bankWindowStart == (u32)0)
            _bankWindowStart = b._bankWindowStart;
        if (_bankWindowEnd == (u32)0)
            _bankWindowEnd = b._bankWindowEnd;
        if (!_hasSplitBanking)
            _hasSplitBanking = b._hasSplitBanking;
        if (_codeWindowStart == (u32)0)
            _codeWindowStart = b._codeWindowStart;
        if (_codeWindowEnd == (u32)0)
            _codeWindowEnd = b._codeWindowEnd;
        if (_dataWindowStart == (u32)0)
            _dataWindowStart = b._dataWindowStart;
        if (_dataWindowEnd == (u32)0)
            _dataWindowEnd = b._dataWindowEnd;
        if (_codeBankReg == (u32)0)
            _codeBankReg = b._codeBankReg;
        if (_dataBankReg == (u32)0)
            _dataBankReg = b._dataBankReg;
        if (!_hasRegionC)
            _hasRegionC = b._hasRegionC;
        if (_regCWindowStart == (u32)0)
            _regCWindowStart = b._regCWindowStart;
        if (_regCWindowEnd == (u32)0)
            _regCWindowEnd = b._regCWindowEnd;
        if (_regCPageSize == (u32)0)
            _regCPageSize = b._regCPageSize;
        if (_regCBankRegLo == (u32)0)
            _regCBankRegLo = b._regCBankRegLo;
        if (_regCBankRegHi == (u32)0)
            _regCBankRegHi = b._regCBankRegHi;
        }

    // ── Reading ──────────────────────────────────────────────────────────
    static XaLayout* read(String* path)
        {
        XaLayout* l = new XaLayout();
        String* text = Files.readText(path);
        String* why = XaPath.readFailure(path, text);
        if (why != (String*)0)
            return l.fail(why);
        return l.parse(path, text);
        }

    XaLayout* parse(String* path, String* text)
        {
        String* baseDir = XaPath.deletingLastComponent(path);
        Array* rawLines = text.splitOnByte((u8)'\n');
        // `#include "file"` lines first: the included layout's values are the
        // defaults this one overrides.
        for (u32 i = (u32)0; i < rawLines.count(); i = i + (u32)1)
            {
            String* trimmed = XaText.tws((String*)rawLines.get(i));
            if (!trimmed.hasPrefix(String.withCString("#include")))
                continue;
            u32 q1 = trimmed.indexOfByte((u8)'"');
            u32 q2 = trimmed.lastIndexOfByte((u8)'"');
            if (q1 == (u32)$FFFF_FFFF || q2 == q1)
                continue;
            String* incName = trimmed.substringBytes(q1 + (u32)1, q2 - q1 - (u32)1);
            String* incPath = XaPath.appending(baseDir, incName);
            // A layout kept outside `layouts/` can still include its siblings
            // there by bare name.
            if (!Files.exists(incPath))
                {
                String* sib = XaPath.appending(XaPath.appending(XaPath.deletingLastComponent(baseDir), String.withCString("layouts")), incName);
                if (Files.exists(sib))
                    incPath = sib;
                }
            XaLayout* base = XaLayout.read(incPath);
            if (base.error() != (String*)0)
                return fail(base.error());
            mergeDefaults(base);
            }

        String* section = (String*)0;
        for (u32 ln = (u32)0; ln < rawLines.count(); ln = ln + (u32)1)
            {
            String* line = (String*)rawLines.get(ln);
            if (XaText.tws(line).hasPrefix(String.withCString("#include")))
                continue;
            u32 hash = line.indexOfByte((u8)'#');
            if (hash != (u32)$FFFF_FFFF)
                line = line.substringBytes((u32)0, hash);
            line = XaText.twsn(line);
            if (line.byteLength() == (u32)0)
                continue;
            if (line.hasPrefix(String.withCString("[")) && line.hasSuffix(String.withCString("]")))
                {
                if (!commitCloaked(path))
                    return self;
                section = line.byteLength() >= (u32)2
                              ? line.substringBytes((u32)1, line.byteLength() - (u32)2).lowercased()
                              : String.withCString("");
                if (section.equals(String.withCString("cloaked")))
                    {
                    _pending = true;
                    _pendingBank = (i32)-1;
                    _pendingBankEnd = (i32)-1;
                    _pendingId = String.withCString("lib");
                    }
                continue;
                }
            u32 eq = line.indexOfByte((u8)'=');
            if (eq == (u32)$FFFF_FFFF)
                {
                String* m = String.withString(path);
                m.appendCString(":");
                m.append(String.withU32(ln + (u32)1));
                m.appendCString(": expected 'key = value'");
                return fail(m);
                }
            String* key = XaText.tws(line.substringBytes((u32)0, eq)).lowercased();
            String* value = XaText.tws(line.substringFromByte(eq + (u32)1));
            if (section == (String*)0)
                {
                String* m = String.withString(path);
                m.appendCString(":");
                m.append(String.withU32(ln + (u32)1));
                m.appendCString(": key '");
                m.append(key);
                m.appendCString("' outside any section");
                return fail(m);
                }
            if (section.equals(String.withCString("memory")))
                {
                if (key.equals(String.withCString("main")))
                    _mainRanges = XaLayout.rangeList(value);
                }
            else if (section.equals(String.withCString("banking")))
                banking(key, value);
            else if (section.equals(String.withCString("cloaked")))
                cloaked(key, value);
            }
        if (!commitCloaked(path))
            return self;
        for (u32 i = (u32)0; i < _cloakedIds.count(); i = i + (u32)1)
            for (u32 j = (u32)0; j < i; j = j + (u32)1)
                if (((String*)_cloakedIds.get(i)).equals((String*)_cloakedIds.get(j)))
                    {
                    String* m = String.withString(path);
                    m.appendCString(": duplicate [cloaked] id '");
                    m.append((String*)_cloakedIds.get(i));
                    m.appendCString("' (check for overlapping `bank = N-M` ranges or repeated `id = ` lines)");
                    return fail(m);
                    }
        return self;
        }
    }
