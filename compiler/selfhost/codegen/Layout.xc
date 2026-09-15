// Layout.xc — the `.lnk` memory layout, read.
// =========================================================================
//
// self-hosting M17. The port of the part of XTMemoryModel the 6502 back end
// consumes. Unlike every other target, xt6502's code generator is not fixed by
// an ABI: the zero-page pools it allocates from, the regions it may place code
// in, the bank windows and their select registers all come from a layout file,
// and `support/xt6502/layouts/xt.lnk` is the single source of truth.
//
// So the back-end port needs this first. The format is a handful of `[section]`
// headers over `key = value` lines, where a value is an address, an
// address RANGE, a comma-separated list of ranges, or a boolean. Comments run
// from `#` to end of line.
//
// Only the fields the back end reads are modelled. A field it never consults is
// not silently defaulted — it is simply absent, so nothing can quietly depend
// on a value this reader invented.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"

// One inclusive address range.
class LayoutRange
    {
    u32 _lo;
    u32 _hi;

    void init(void)
        {
        _lo = (u32)0;
        _hi = (u32)0;
        }

    static LayoutRange* with(u32 lo, u32 hi)
        {
        LayoutRange* r = new LayoutRange();
        r._lo = lo;
        r._hi = hi;
        return r;
        }

    u32 lo(void)
        {
        return _lo;
        }
    u32 hi(void)
        {
        return _hi;
        }
    }

    class Layout
    {
    String* _name;

    // ── Zero page ────────────────────────────────────────────────────────
    u32 _hpStart;
    u32 _hpEnd;
    u32 _arcStart;
    u32 _arcEnd;
    u32 _runtimeStart;
    u32 _runtimeEnd;
    Array* _varsRanges; // LayoutRange@, the back end's ZP slot pool

    // ── Main memory ──────────────────────────────────────────────────────
    Array* _mainRanges; // LayoutRange@, where code and data may go
    u32 _systemStart;
    u32 _systemEnd;
    u32 _screenStart;
    u32 _screenEnd;

    // ── Banking ──────────────────────────────────────────────────────────
    bool _hasBanking;
    u32 _codeWindowStart;
    u32 _codeWindowEnd;
    u32 _dataWindowStart;
    u32 _dataWindowEnd;
    u32 _codeBankReg;
    u32 _dataBankReg;

    // ── Stack, heap, entry ───────────────────────────────────────────────
    u32 _stackStart;
    u32 _stackEnd;
    u32 _heapStart;
    u32 _heapEnd;
    bool _heapBanked;
    u32 _heapBankFirst;
    u32 _heapBankLast;
    bool _heapBankDynamic;
    u32 _entryAddress;

    bool _failed;
    String* _why;

    void init(void)
        {
        _name = String.withCString("");
        _varsRanges = new Array();
        _mainRanges = new Array();
        _hasBanking = false;
        _heapBanked = false;
        _failed = false;
        _hpStart = (u32)0;
        _hpEnd = (u32)0;
        _arcStart = (u32)0;
        _arcEnd = (u32)0;
        _runtimeStart = (u32)0;
        _runtimeEnd = (u32)0;
        _systemStart = (u32)0;
        _systemEnd = (u32)0;
        _screenStart = (u32)0;
        _screenEnd = (u32)0;
        _codeWindowStart = (u32)0;
        _codeWindowEnd = (u32)0;
        _dataWindowStart = (u32)0;
        _dataWindowEnd = (u32)0;
        _codeBankReg = (u32)0;
        _dataBankReg = (u32)0;
        _stackStart = (u32)0;
        _stackEnd = (u32)0;
        _heapStart = (u32)0;
        _heapEnd = (u32)0;
        _heapBankFirst = (u32)0;
        _heapBankLast = (u32)0;
        _heapBankDynamic = false;
        _entryAddress = (u32)0;
        }

    String* name(void)
        {
        return _name;
        }
    void setName(String* n)
        {
        _name = n;
        }
    bool failed(void)
        {
        return _failed;
        }
    String* why(void)
        {
        return _why;
        }

    Array* varsRanges(void)
        {
        return _varsRanges;
        }
    Array* mainRanges(void)
        {
        return _mainRanges;
        }
    u32 hpStart(void)
        {
        return _hpStart;
        }
    u32 hpEnd(void)
        {
        return _hpEnd;
        }
    u32 arcStart(void)
        {
        return _arcStart;
        }
    u32 arcEnd(void)
        {
        return _arcEnd;
        }
    u32 runtimeStart(void)
        {
        return _runtimeStart;
        }
    u32 runtimeEnd(void)
        {
        return _runtimeEnd;
        }
    u32 systemStart(void)
        {
        return _systemStart;
        }
    u32 systemEnd(void)
        {
        return _systemEnd;
        }
    u32 screenStart(void)
        {
        return _screenStart;
        }
    u32 screenEnd(void)
        {
        return _screenEnd;
        }
    bool hasBanking(void)
        {
        return _hasBanking;
        }
    u32 codeWindowStart(void)
        {
        return _codeWindowStart;
        }
    u32 codeWindowEnd(void)
        {
        return _codeWindowEnd;
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
    u32 stackStart(void)
        {
        return _stackStart;
        }
    u32 stackEnd(void)
        {
        return _stackEnd;
        }
    u32 heapStart(void)
        {
        return _heapStart;
        }
    u32 heapEnd(void)
        {
        return _heapEnd;
        }
    bool heapBanked(void)
        {
        return _heapBanked;
        }
    u32 heapBankFirst(void)
        {
        return _heapBankFirst;
        }
    u32 heapBankLast(void)
        {
        return _heapBankLast;
        }
    bool heapBankDynamic(void)
        {
        return _heapBankDynamic;
        }
    // One page per window, so the page size IS the data window's length —
    // derived, never declared, exactly as the [banking] comment says.
    u32 dataPageSize(void)
        {
        if (_dataWindowEnd < _dataWindowStart)
            return (u32)0;
        return _dataWindowEnd - _dataWindowStart + (u32)1;
        }
    u32 entryAddress(void)
        {
        return _entryAddress;
        }

    // The bank window is the CODE window: this back end never places code in
    // the data window, so "the window a function can be banked into" is
    // unambiguous.
    u32 bankWindowStart(void)
        {
        return _codeWindowStart;
        }
    u32 bankWindowEnd(void)
        {
        return _codeWindowEnd;
        }

    void fail(String* w)
        {
        if (_failed)
            return;
        _failed = true;
        _why = w;
        }

    // ── Reading ──────────────────────────────────────────────────────────
    static Layout* read(String* path)
        {
        Layout* l = new Layout();
        String* text = Files.readText(path);
        if (text == (String*)0)
            {
            l.fail(String.withCString("cannot read layout"));
            return l;
            }
        l.parse(text);
        return l;
        }

    void parse(String* text)
        {
        String* section = String.withCString("");
        Array* lines = text.splitOnByte((u8)'\n');
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* line = stripComment((String*)lines.get(i)).trimmed();
            if (line.byteLength() == (u32)0)
                continue;
            if (line.byteAt((u32)0) == (u8)'[')
                {
                u32 close = line.indexOfByte((u8)']');
                if (close == (u32)$FFFF_FFFF)
                    continue;
                section = line.substringBytes((u32)1, close - (u32)1);
                continue;
                }
            u32 eq = line.indexOfByte((u8)'=');
            if (eq == (u32)$FFFF_FFFF)
                continue;
            String* key = line.substringBytes((u32)0, eq).trimmed();
            String* val = line.substringFromByte(eq + (u32)1).trimmed();
            apply(section, key, val);
            }
        }

    // A `#` starts a comment, and the layouts use it liberally for the map
    // diagrams — so it has to be stripped before anything else looks at the
    // line.
    static String* stripComment(String* line)
        {
        u32 h = line.indexOfByte((u8)'#');
        return h == (u32)$FFFF_FFFF ? line : line.substringBytes((u32)0, h);
        }

    void apply(String* section, String* key, String* val)
        {
        if (section.equals(String.withCString("zp")))
            {
            applyZp(key, val);
            return;
            }
        if (section.equals(String.withCString("memory")))
            {
            applyMemory(key, val);
            return;
            }
        if (section.equals(String.withCString("banking")))
            {
            applyBanking(key, val);
            return;
            }
        if (section.equals(String.withCString("stack")))
            {
            applyStack(key, val);
            return;
            }
        if (section.equals(String.withCString("heap")))
            {
            applyHeap(key, val);
            return;
            }
        if (section.equals(String.withCString("entry")))
            {
            if (key.equals(String.withCString("address")))
                _entryAddress = number(val);
            return;
            }
        // An unknown section is IGNORED rather than an error: the layouts carry
        // sections other tools read, and refusing them would couple this reader
        // to every consumer.
        }

    void applyZp(String* key, String* val)
        {
        if (key.equals(String.withCString("hp")))
            {
            readRange(val, &_hpStart, &_hpEnd);
            return;
            }
        if (key.equals(String.withCString("arc-scratch")))
            {
            readRange(val, &_arcStart, &_arcEnd);
            return;
            }
        if (key.equals(String.withCString("runtime")))
            {
            readRange(val, &_runtimeStart, &_runtimeEnd);
            return;
            }
        if (key.equals(String.withCString("vars")))
            {
            _varsRanges = readRangeList(val);
            return;
            }
        }

    void applyMemory(String* key, String* val)
        {
        if (key.equals(String.withCString("system")))
            {
            readRange(val, &_systemStart, &_systemEnd);
            return;
            }
        if (key.equals(String.withCString("screen")))
            {
            readRange(val, &_screenStart, &_screenEnd);
            return;
            }
        if (key.equals(String.withCString("main")))
            {
            _mainRanges = readRangeList(val);
            return;
            }
        }

    void applyBanking(String* key, String* val)
        {
        if (key.equals(String.withCString("code-window")))
            {
            readRange(val, &_codeWindowStart, &_codeWindowEnd);
            _hasBanking = true;
            return;
            }
        if (key.equals(String.withCString("data-window")))
            {
            readRange(val, &_dataWindowStart, &_dataWindowEnd);
            return;
            }
        if (key.equals(String.withCString("code-reg")))
            {
            _codeBankReg = number(val);
            return;
            }
        if (key.equals(String.withCString("data-reg")))
            {
            _dataBankReg = number(val);
            return;
            }
        // `registers = <code>, <data>` is the older spelling of the two
        // selectors; both forms appear in the tree.
        if (key.equals(String.withCString("registers")))
            {
            Array* parts = val.splitOnByte((u8)',');
            if (parts.count() >= (u32)1)
                _codeBankReg = number(((String*)parts.get((u32)0)).trimmed());
            if (parts.count() >= (u32)2)
                _dataBankReg = number(((String*)parts.get((u32)1)).trimmed());
            return;
            }
        }

    void applyStack(String* key, String* val)
        {
        if (key.equals(String.withCString("range")))
            readRange(val, &_stackStart, &_stackEnd);
        }

    void applyHeap(String* key, String* val)
        {
        if (key.equals(String.withCString("range")))
            {
            readRange(val, &_heapStart, &_heapEnd);
            return;
            }
        if (key.equals(String.withCString("bank")))
            {
            // `bank = true|on|dynamic` — claim data banks ON DEMAND, so the
            // usable range is the whole 8-bit data selector minus bank 0
            // (which is the resident window). `bank = $lo-$hi` names an
            // explicit range instead and is NOT dynamic. Same derivation the
            // original does in XTLinkerScriptParser; the runtime emitter
            // writes these three out as heap_bank_first/last/dynamic, so a
            // different answer here is a different heap.
            if (isTrue(val) || val.equals(String.withCString("dynamic")))
                {
                _heapBanked = true;
                _heapBankDynamic = true;
                _heapBankFirst = (u32)1;
                _heapBankLast = (u32)$FF;
                return;
                }
            u32 lo = (u32)0;
            u32 hi = (u32)0;
            if (val.byteIndexOf(String.withCString("-")) != (u32)$FFFF_FFFF)
                {
                readRange(val, &lo, &hi);
                _heapBanked = true;
                _heapBankDynamic = false;
                _heapBankFirst = lo;
                _heapBankLast = hi;
                return;
                }
            _heapBanked = false;
            return;
            }
        }

    static bool isTrue(String* v)
        {
        return v.equals(String.withCString("true")) || v.equals(String.withCString("yes")) || v.equals(String.withCString("1"));
        }

    // `$LO-$HI`, or a bare address for a one-byte range.
    void readRange(String* v, u32* lo, u32* hi)
        {
        u32 dash = dashAt(v);
        if (dash == (u32)$FFFF_FFFF)
            {
            *lo = number(v);
            *hi = *lo;
            return;
            }
        *lo = number(v.substringBytes((u32)0, dash).trimmed());
        *hi = number(v.substringFromByte(dash + (u32)1).trimmed());
        }

    // The separating dash, which is NOT the one that could open a negative
    // number — an address is always `$hex` or decimal here, so the first dash
    // past position 0 separates.
    static u32 dashAt(String* v)
        {
        for (u32 i = (u32)1; i < v.byteLength(); i = i + (u32)1)
            if (v.byteAt(i) == (u8)'-')
                return i;
        return (u32)$FFFF_FFFF;
        }

    Array* readRangeList(String* v)
        {
        Array* out = new Array();
        Array* parts = v.splitOnByte((u8)',');
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
            {
            String* p = ((String*)parts.get(i)).trimmed();
            if (p.byteLength() == (u32)0)
                continue;
            u32 lo = (u32)0;
            u32 hi = (u32)0;
            readRange(p, &lo, &hi);
            out.add((Object*)LayoutRange.with(lo, hi));
            }
        return out;
        }

    // `$` introduces hex, and `_` is ignored inside a literal — the same
    // spelling the language itself uses.
    static u32 number(String* v)
        {
        if (v.byteLength() == (u32)0)
            return (u32)0;
        u32 i = (u32)0;
        bool hex = false;
        if (v.byteAt((u32)0) == (u8)'$')
            {
            hex = true;
            i = (u32)1;
            }
        else if (v.byteLength() > (u32)1 && v.byteAt((u32)0) == (u8)'0' && (v.byteAt((u32)1) == (u8)'x' || v.byteAt((u32)1) == (u8)'X'))
            {
            hex = true;
            i = (u32)2;
            }
        u32 n = (u32)0;
        for (; i < v.byteLength(); i = i + (u32)1)
            {
            u8 c = v.byteAt(i);
            if (c == (u8)'_')
                continue;
            i32 d = digitOf(c);
            if (d < (i32)0)
                break;
            if (!hex && d > (i32)9)
                break;
            n = n * (hex ? (u32)16 : (u32)10) + (u32)d;
            }
        return n;
        }

    static i32 digitOf(u8 c)
        {
        if (c >= (u8)'0' && c <= (u8)'9')
            return (i32)(c - (u8)'0');
        if (c >= (u8)'a' && c <= (u8)'f')
            return (i32)(c - (u8)'a') + (i32)10;
        if (c >= (u8)'A' && c <= (u8)'F')
            return (i32)(c - (u8)'A') + (i32)10;
        return (i32)-1;
        }
    }
