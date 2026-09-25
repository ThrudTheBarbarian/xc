// LayoutMap.xc — a memory layout's map, as `xcc -dl` prints it.
// =================================================================
//
// `-dl` / `--dump-layout` draws the regions a `.lnk` layout declares as a
// boxed memory map. The code generator's own reader (codegen/Layout.xc) keeps
// only what the 6502 back end consumes; the map shows more — the split and
// region-C bank selectors, the shadow register, the stack placement — so this
// reads the file itself, with the same rules as the layout reader in the
// original compiler: keys and section names are case-insensitive, a
// `#include "file"` is read first and supplies defaults, and the first local
// `[stack]` header clears whatever `[stack]` an include set.
//
// The output is compared line for line with the original's, so the wording,
// the order of the regions and the padding are all part of the contract.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Files.xc"

class LayoutMap
{
    String* _name;
    String* _path;
    bool    _failed;
    String* _why;

    u32 _zpSPStart;        u32 _zpSPEnd;
    u32 _zpTmpStart;       u32 _zpTmpEnd;
    u32 _zpHPStart;        u32 _zpHPEnd;
    u32 _zpRuntimeStart;   u32 _zpRuntimeEnd;
    u32 _zpBankRegStart;   u32 _zpBankRegEnd;
    Array* _zpVars;        // Number@ pairs: lo, hi, lo, hi, …
    Array* _mainRanges;    // …the same
    u32 _systemStart;      u32 _systemEnd;
    u32 _screenStart;      u32 _screenEnd;

    bool _hasBanking;
    u32 _bankWindowStart;  u32 _bankWindowEnd;
    Array* _bankRegs;      // Number@ pairs: address, mask
    bool _hasSplit;
    u32 _codeWindowStart;  u32 _codeWindowEnd;
    u32 _dataWindowStart;  u32 _dataWindowEnd;
    u32 _codeBankReg;      u32 _dataBankReg;
    u32 _codeRegionSpan;   u32 _dataRegionSpan;
    bool _hasRegionC;
    u32 _regCWindowStart;  u32 _regCWindowEnd;
    u32 _regCBankRegLo;    u32 _regCBankRegHi;
    u32 _regCRegionSpan;

    bool _hasShadow;
    u32 _shadowRegAddr;    u32 _shadowRegMask;
    u32 _trampolineStart;  u32 _trampolineEnd;

    String* _stackBase;
    u32 _heapTop;
    u32 _entryAddress;

    void init(void)
    {
        _name = (String*)0;
        _path = (String*)0;
        _failed = false;
        _why = (String*)0;
        _zpVars = (Array*)0;
        _mainRanges = (Array*)0;
        _bankRegs = (Array*)0;
        _stackBase = (String*)0;
        _hasBanking = false;
        _hasSplit = false;
        _hasRegionC = false;
        _hasShadow = false;
    }

    bool failed(void) { return _failed; }
    String* why(void) { return _why; }

    static LayoutMap* read(String* path)
    {
        LayoutMap* m = new LayoutMap();
        m.parseFile(path);
        return m;
    }

    void fail(String* w)
    {
        if (_failed) return;
        _failed = true;
        _why = w;
    }

    // ── reading ──────────────────────────────────────────────────────────
    void parseFile(String* path)
    {
        _path = path;
        String* text = Files.readText(path);
        if (text == (String*)0) {
            fail(String.withFormat("cannot read '%s'", path.cString()));
            return;
        }
        Array* lines = text.splitOnByte((u8)'\n');
        // Includes first: each supplies defaults for what this file leaves unset.
        String* dir = path.deletingLastPathComponent();
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
            String* t = ((String*)lines.get(i)).trimmed();
            if (!t.hasPrefix(String.withCString("#include"))) continue;
            u32 q1 = t.indexOfByte((u8)'"');
            u32 q2 = lastIndexOfByte(t, (u8)'"');
            if (q1 == String.notFound() || q2 == q1) continue;
            String* inc = t.substringBytes(q1 + (u32)1, q2 - q1 - (u32)1);
            String* incPath = joinPath(dir, inc);
            // An include that is not beside the file is looked for in the
            // platform's layouts/ directory, one level up.
            if (!Files.exists(incPath)) {
                String* sib = joinPath(joinPath(dir.deletingLastPathComponent(),
                                                String.withCString("layouts")), inc);
                if (Files.exists(sib)) incPath = sib;
            }
            LayoutMap* base = LayoutMap.read(incPath);
            if (base.failed()) { fail(base.why()); return; }
            mergeDefaults(base);
        }
        String* section = (String*)0;
        bool stackReset = false;
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1) {
            String* line = (String*)lines.get(i);
            if (line.trimmed().hasPrefix(String.withCString("#include"))) continue;
            u32 hash = line.indexOfByte((u8)'#');
            if (hash != String.notFound()) line = line.substringBytes((u32)0, hash);
            line = line.trimmed();
            if (line.byteLength() == (u32)0) continue;
            if (line.byteAt((u32)0) == (u8)'[' && line.byteAt(line.byteLength() - (u32)1) == (u8)']') {
                section = line.substringBytes((u32)1, line.byteLength() - (u32)2).lowercased();
                if (section.equals(String.withCString("stack")) && !stackReset) {
                    _stackBase = (String*)0;
                    stackReset = true;
                }
                continue;
            }
            u32 eq = line.indexOfByte((u8)'=');
            if (eq == String.notFound()) {
                fail(String.withFormat("%s:%u: expected 'key = value'", path.cString(), i + (u32)1));
                return;
            }
            String* key = line.substringBytes((u32)0, eq).trimmed().lowercased();
            String* val = line.substringFromByte(eq + (u32)1).trimmed();
            if (section == (String*)0) {
                fail(String.withFormat("%s:%u: key '%s' outside any section",
                                       path.cString(), i + (u32)1, key.cString()));
                return;
            }
            apply(section, key, val);
        }
        if (_name == (String*)0) _name = path.lastPathComponent().deletingPathExtension();
    }

    static u32 lastIndexOfByte(String* s, u8 b)
    {
        u32 at = String.notFound();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            if (s.byteAt(i) == b) at = i;
        return at;
    }

    static String* joinPath(String* dir, String* name)
    {
        if (dir == (String*)0 || dir.byteLength() == (u32)0) return String.withString(name);
        String* p = String.withString(dir);
        if (!p.hasSuffix(String.withCString("/"))) p.appendCString("/");
        p.append(name);
        return p;
    }

    // Every field this file left unset takes the included layout's value.
    void mergeDefaults(LayoutMap* b)
    {
        if (_zpSPStart == (u32)0) _zpSPStart = b._zpSPStart;
        if (_zpSPEnd == (u32)0) _zpSPEnd = b._zpSPEnd;
        if (_zpTmpStart == (u32)0) _zpTmpStart = b._zpTmpStart;
        if (_zpTmpEnd == (u32)0) _zpTmpEnd = b._zpTmpEnd;
        if (_zpHPStart == (u32)0) _zpHPStart = b._zpHPStart;
        if (_zpHPEnd == (u32)0) _zpHPEnd = b._zpHPEnd;
        if (_zpVars == (Array*)0) _zpVars = b._zpVars;
        if (_zpRuntimeStart == (u32)0) _zpRuntimeStart = b._zpRuntimeStart;
        if (_zpRuntimeEnd == (u32)0) _zpRuntimeEnd = b._zpRuntimeEnd;
        if (_zpBankRegStart == (u32)0) _zpBankRegStart = b._zpBankRegStart;
        if (_zpBankRegEnd == (u32)0) _zpBankRegEnd = b._zpBankRegEnd;
        if (_mainRanges == (Array*)0) _mainRanges = b._mainRanges;
        if (_systemStart == (u32)0) _systemStart = b._systemStart;
        if (_systemEnd == (u32)0) _systemEnd = b._systemEnd;
        if (_screenStart == (u32)0) _screenStart = b._screenStart;
        if (_screenEnd == (u32)0) _screenEnd = b._screenEnd;
        if (!_hasBanking) _hasBanking = b._hasBanking;
        if (_bankWindowStart == (u32)0) _bankWindowStart = b._bankWindowStart;
        if (_bankWindowEnd == (u32)0) _bankWindowEnd = b._bankWindowEnd;
        if (_bankRegs == (Array*)0) _bankRegs = b._bankRegs;
        if (!_hasSplit) _hasSplit = b._hasSplit;
        if (_codeWindowStart == (u32)0) _codeWindowStart = b._codeWindowStart;
        if (_codeWindowEnd == (u32)0) _codeWindowEnd = b._codeWindowEnd;
        if (_dataWindowStart == (u32)0) _dataWindowStart = b._dataWindowStart;
        if (_dataWindowEnd == (u32)0) _dataWindowEnd = b._dataWindowEnd;
        if (_codeBankReg == (u32)0) _codeBankReg = b._codeBankReg;
        if (_dataBankReg == (u32)0) _dataBankReg = b._dataBankReg;
        if (_codeRegionSpan == (u32)0) _codeRegionSpan = b._codeRegionSpan;
        if (_dataRegionSpan == (u32)0) _dataRegionSpan = b._dataRegionSpan;
        if (!_hasRegionC) _hasRegionC = b._hasRegionC;
        if (_regCWindowStart == (u32)0) _regCWindowStart = b._regCWindowStart;
        if (_regCWindowEnd == (u32)0) _regCWindowEnd = b._regCWindowEnd;
        if (_regCBankRegLo == (u32)0) _regCBankRegLo = b._regCBankRegLo;
        if (_regCBankRegHi == (u32)0) _regCBankRegHi = b._regCBankRegHi;
        if (_regCRegionSpan == (u32)0) _regCRegionSpan = b._regCRegionSpan;
        if (!_hasShadow) _hasShadow = b._hasShadow;
        if (_shadowRegAddr == (u32)0) _shadowRegAddr = b._shadowRegAddr;
        if (_shadowRegMask == (u32)0) _shadowRegMask = b._shadowRegMask;
        if (_trampolineStart == (u32)0) _trampolineStart = b._trampolineStart;
        if (_trampolineEnd == (u32)0) _trampolineEnd = b._trampolineEnd;
        if (_stackBase == (String*)0) _stackBase = b._stackBase;
        if (_heapTop == (u32)0) _heapTop = b._heapTop;
        if (_entryAddress == (u32)0) _entryAddress = b._entryAddress;
    }

    void apply(String* section, String* key, String* val)
    {
        if (section.equals(String.withCString("zp")))           applyZp(key, val);
        else if (section.equals(String.withCString("memory")))  applyMemory(key, val);
        else if (section.equals(String.withCString("banking"))) applyBanking(key, val);
        else if (section.equals(String.withCString("shadow")))  applyShadow(key, val);
        else if (section.equals(String.withCString("stack"))) {
            if (key.equals(String.withCString("base"))) _stackBase = val;
        }
        else if (section.equals(String.withCString("heap"))) {
            u32 lo = (u32)0; u32 hi = (u32)0;
            if (key.equals(String.withCString("top"))) { if (number16(val, &lo)) _heapTop = lo; }
            else if (key.equals(String.withCString("range"))) { if (range(val, &lo, &hi)) _heapTop = hi; }
        }
        else if (section.equals(String.withCString("entry"))) {
            u32 v = (u32)0;
            if (key.equals(String.withCString("address")) && number16(val, &v)) _entryAddress = v;
        }
    }

    void applyZp(String* key, String* val)
    {
        u32 lo = (u32)0; u32 hi = (u32)0;
        if (key.equals(String.withCString("vars"))) { _zpVars = rangeList(val); return; }
        if (!range(val, &lo, &hi)) return;
        if (key.equals(String.withCString("sp")))           { _zpSPStart = lo; _zpSPEnd = hi; }
        else if (key.equals(String.withCString("tmp")))     { _zpTmpStart = lo; _zpTmpEnd = hi; }
        else if (key.equals(String.withCString("hp")))      { _zpHPStart = lo; _zpHPEnd = hi; }
        else if (key.equals(String.withCString("runtime"))) { _zpRuntimeStart = lo; _zpRuntimeEnd = hi; }
        else if (key.equals(String.withCString("bankreg"))) { _zpBankRegStart = lo; _zpBankRegEnd = hi; }
    }

    void applyMemory(String* key, String* val)
    {
        u32 lo = (u32)0; u32 hi = (u32)0;
        if (key.equals(String.withCString("main"))) { _mainRanges = rangeList(val); return; }
        if (!range(val, &lo, &hi)) return;
        if (key.equals(String.withCString("system")))      { _systemStart = lo; _systemEnd = hi; }
        else if (key.equals(String.withCString("screen"))) { _screenStart = lo; _screenEnd = hi; }
    }

    // The split view keeps the single-window fields coherent: the window runs
    // from the code half's start to the data half's end, and both selectors are
    // listed — using whatever the file has declared by this point.
    void syncSplitToLegacy(void)
    {
        if (!_hasSplit) return;
        if (_codeWindowStart != (u32)0) _bankWindowStart = _codeWindowStart;
        if (_dataWindowEnd != (u32)0) _bankWindowEnd = _dataWindowEnd;
        if (_codeBankReg != (u32)0 && _dataBankReg != (u32)0) {
            _bankRegs = new Array();
            _bankRegs.add((Object*)Number.withU32(_codeBankReg));
            _bankRegs.add((Object*)Number.withU32((u32)$FF));
            _bankRegs.add((Object*)Number.withU32(_dataBankReg));
            _bankRegs.add((Object*)Number.withU32((u32)$FF));
        }
    }

    void applyBanking(String* key, String* val)
    {
        _hasBanking = true;
        u32 lo = (u32)0; u32 hi = (u32)0; u32 v = (u32)0;
        // `<name>-window` / `<name>-reg`: `code` and `data` are the two
        // well-known regions; any other name is a region the map does not draw.
        if (key.hasSuffix(String.withCString("-window"))) {
            String* nm = key.substringBytes((u32)0, key.byteLength() - (u32)7);
            if (!range(val, &lo, &hi)) return;
            if (nm.equals(String.withCString("code")))      { _bankWindowStart = lo; _bankWindowEnd = hi; }
            else if (nm.equals(String.withCString("data"))) { _dataWindowStart = lo; _dataWindowEnd = hi; }
            return;
        }
        if (key.hasSuffix(String.withCString("-reg"))) {
            String* nm = key.substringBytes((u32)0, key.byteLength() - (u32)4);
            if (!number16(val, &v)) return;
            if (nm.equals(String.withCString("code")))      _codeBankReg = v;
            else if (nm.equals(String.withCString("data"))) _dataBankReg = v;
            return;
        }
        if (key.equals(String.withCString("window"))) {
            if (range(val, &lo, &hi)) { _bankWindowStart = lo; _bankWindowEnd = hi; }
        } else if (key.equals(String.withCString("registers"))) {
            _bankRegs = registerList(val);
            // Plain 8-bit selectors (mask $FF) name the code and data registers.
            if (_bankRegs.count() >= (u32)2 && ((Number*)_bankRegs.get((u32)1)).asU32() == (u32)$FF)
                _codeBankReg = ((Number*)_bankRegs.get((u32)0)).asU32();
            if (_bankRegs.count() >= (u32)4 && ((Number*)_bankRegs.get((u32)3)).asU32() == (u32)$FF)
                _dataBankReg = ((Number*)_bankRegs.get((u32)2)).asU32();
        } else if (key.equals(String.withCString("codewindow"))) {
            if (range(val, &lo, &hi)) {
                _hasSplit = true;
                _codeWindowStart = lo; _codeWindowEnd = hi;
                syncSplitToLegacy();
            }
        } else if (key.equals(String.withCString("datawindow"))) {
            if (range(val, &lo, &hi)) { _dataWindowStart = lo; _dataWindowEnd = hi; }
        } else if (key.equals(String.withCString("codereg"))) {
            if (number16(val, &v)) _codeBankReg = v;
        } else if (key.equals(String.withCString("datareg"))) {
            if (number16(val, &v)) _dataBankReg = v;
        } else if (key.equals(String.withCString("coderegion")) || key.equals(String.withCString("coderegionspan"))) {
            if (number32(val, &v)) _codeRegionSpan = v;
        } else if (key.equals(String.withCString("dataregion")) || key.equals(String.withCString("dataregionspan"))) {
            if (number32(val, &v)) _dataRegionSpan = v;
        } else if (key.equals(String.withCString("regcwindow"))) {
            if (range(val, &lo, &hi)) { _hasRegionC = true; _regCWindowStart = lo; _regCWindowEnd = hi; }
        } else if (key.equals(String.withCString("regcpagesize"))) {
            if (number16(val, &v)) _hasRegionC = true;
        } else if (key.equals(String.withCString("regcreg"))) {
            if (range(val, &lo, &hi)) {
                _hasRegionC = true; _regCBankRegLo = lo; _regCBankRegHi = hi;
            } else if (number16(val, &v)) {
                _hasRegionC = true; _regCBankRegLo = v; _regCBankRegHi = (u32)0;
            }
        } else if (key.equals(String.withCString("regcregion")) || key.equals(String.withCString("regcregionspan"))) {
            if (number32(val, &v)) { _hasRegionC = true; _regCRegionSpan = v; }
        }
    }

    void applyShadow(String* key, String* val)
    {
        _hasShadow = true;
        u32 lo = (u32)0; u32 hi = (u32)0;
        if (key.equals(String.withCString("register"))) {
            if (registerSpec(val, &lo, &hi)) { _shadowRegAddr = lo; _shadowRegMask = hi; }
        } else if (key.equals(String.withCString("trampoline"))) {
            if (range(val, &lo, &hi)) { _trampolineStart = lo; _trampolineEnd = hi; }
        }
    }

    // ── value grammar ────────────────────────────────────────────────────
    //
    // `$hex` or decimal, the whole of the text, kept to 16 bits.
    static bool number16(String* s, u32* out)
    {
        u32 v = (u32)0;
        if (!number32(s, &v)) return false;
        *out = v & (u32)$FFFF;
        return true;
    }

    static bool number32(String* s, u32* out)
    {
        String* t = s.trimmed();
        if (t.byteLength() == (u32)0) return false;
        u32 i = (u32)0;
        bool hex = false;
        if (t.byteAt((u32)0) == (u8)'$') { hex = true; i = (u32)1; }
        else if (t.byteAt((u32)0) == (u8)'-' || t.byteAt((u32)0) == (u8)'+') i = (u32)1;
        if (i >= t.byteLength()) return false;
        u32 v = (u32)0;
        for (; i < t.byteLength(); i = i + (u32)1) {
            u8 c = t.byteAt(i);
            i32 dgt = (i32)-1;
            if (c >= (u8)'0' && c <= (u8)'9') dgt = (i32)(c - (u8)'0');
            else if (hex && c >= (u8)'a' && c <= (u8)'f') dgt = (i32)(c - (u8)'a') + (i32)10;
            else if (hex && c >= (u8)'A' && c <= (u8)'F') dgt = (i32)(c - (u8)'A') + (i32)10;
            if (dgt < (i32)0) return false;
            v = v * (hex ? (u32)16 : (u32)10) + (u32)dgt;
        }
        *out = v;
        return true;
    }

    static bool isHexDigit(u8 c)
    {
        return (c >= (u8)'0' && c <= (u8)'9') || (c >= (u8)'a' && c <= (u8)'f')
            || (c >= (u8)'A' && c <= (u8)'F');
    }

    // The first `$hex - $hex` in the text. Ranges are always written in hex,
    // which is what tells the separating dash from a sign.
    static bool range(String* s, u32* lo, u32* hi)
    {
        u32 n = s.byteLength();
        for (u32 i = (u32)0; i < n; i = i + (u32)1) {
            if (s.byteAt(i) != (u8)'$') continue;
            u32 a = i + (u32)1;
            u32 e = a;
            while (e < n && isHexDigit(s.byteAt(e))) e = e + (u32)1;
            if (e == a) continue;
            u32 j = e;
            while (j < n && (s.byteAt(j) == (u8)' ' || s.byteAt(j) == (u8)9)) j = j + (u32)1;
            if (j >= n || s.byteAt(j) != (u8)'-') continue;
            j = j + (u32)1;
            while (j < n && (s.byteAt(j) == (u8)' ' || s.byteAt(j) == (u8)9)) j = j + (u32)1;
            if (j >= n || s.byteAt(j) != (u8)'$') continue;
            u32 b = j + (u32)1;
            u32 f = b;
            while (f < n && isHexDigit(s.byteAt(f))) f = f + (u32)1;
            if (f == b) continue;
            u32 x = (u32)0; u32 y = (u32)0;
            if (!number16(s.substringBytes(i, e - i), &x)) return false;
            if (!number16(s.substringBytes(j, f - j), &y)) return false;
            *lo = x;
            *hi = y;
            return true;
        }
        return false;
    }

    static Array* rangeList(String* s)
    {
        Array* out = new Array();
        Array* parts = s.splitOnByte((u8)',');
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1) {
            u32 lo = (u32)0; u32 hi = (u32)0;
            if (range((String*)parts.get(i), &lo, &hi)) {
                out.add((Object*)Number.withU32(lo));
                out.add((Object*)Number.withU32(hi));
            }
        }
        return out;
    }

    // `$addr` (mask $FF) or `$addr:$mask`.
    static bool registerSpec(String* s, u32* addr, u32* mask)
    {
        Array* parts = s.trimmed().splitOnByte((u8)':');
        u32 a = (u32)0; u32 m = (u32)0;
        if (parts.count() == (u32)1) {
            if (!number16((String*)parts.get((u32)0), &a)) return false;
            *addr = a; *mask = (u32)$FF;
            return true;
        }
        if (parts.count() == (u32)2) {
            if (!number16((String*)parts.get((u32)0), &a)) return false;
            if (!number16((String*)parts.get((u32)1), &m)) return false;
            *addr = a; *mask = m & (u32)$FF;
            return true;
        }
        return false;
    }

    static Array* registerList(String* s)
    {
        Array* out = new Array();
        Array* parts = s.splitOnByte((u8)',');
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1) {
            u32 a = (u32)0; u32 m = (u32)0;
            if (registerSpec((String*)parts.get(i), &a, &m)) {
                out.add((Object*)Number.withU32(a));
                out.add((Object*)Number.withU32(m));
            }
        }
        return out;
    }

    // ── the map ──────────────────────────────────────────────────────────
    //
    // Upper-case hex, at least `width` digits.
    static String* hex(u32 v, u32 width)
    {
        String* digits = new String();
        u32 x = v;
        if (x == (u32)0) digits.appendByte((u8)'0');
        while (x != (u32)0) {
            u32 d = x & (u32)15;
            digits.appendByte(d < (u32)10 ? (u8)((u32)'0' + d) : (u8)((u32)'A' + d - (u32)10));
            x = x >> (u32)4;
        }
        String* out = new String();
        for (u32 k = digits.byteLength(); k < width; k = k + (u32)1) out.appendByte((u8)'0');
        for (u32 k = digits.byteLength(); k > (u32)0; k = k - (u32)1) out.appendByte(digits.byteAt(k - (u32)1));
        return out;
    }

    static String* dec(u32 v)
    {
        return String.withFormat("%lu", v);
    }

    // The width the original pads to counts UTF-16 units, not bytes: the
    // arrows in the stack and heap lines are three bytes and one unit.
    static u32 units(String* s)
    {
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            if ((s.byteAt(i) & (u8)$C0) != (u8)$80) n = n + (u32)1;
        return n;
    }

    static String* repeat(string piece, u32 n)
    {
        String* out = new String();
        for (u32 i = (u32)0; i < n; i = i + (u32)1) out.appendCString(piece);
        return out;
    }

    static String* range4(u32 lo, u32 hi)
    {
        String* s = String.withCString("$");
        s.append(hex(lo, (u32)4));
        s.appendCString("-$");
        s.append(hex(hi, (u32)4));
        return s;
    }

    // Regions, held as three parallel arrays and kept in start order. An
    // insertion keeps equal starts in the order they were added.
    Array* _rs; Array* _re; Array* _rl;

    void region(u32 lo, u32 hi, String* label)
    {
        u32 at = _rs.count();
        while (at > (u32)0 && ((Number*)_rs.get(at - (u32)1)).asU32() > lo) at = at - (u32)1;
        _rs.insert(at, (Object*)Number.withU32(lo));
        _re.insert(at, (Object*)Number.withU32(hi));
        _rl.insert(at, (Object*)label);
    }

    static String* spanLabel(u32 bytes)
    {
        u32 mb = (u32)1 << (u32)20;
        if (bytes >= mb && bytes % mb == (u32)0) return String.withFormat("%lu MB addressable", bytes / mb);
        if (bytes >= (u32)1024) return String.withFormat("%lu KB addressable", bytes / (u32)1024);
        return String.withFormat("%lu B addressable", bytes);
    }

    String* diagram(void)
    {
        String* lnkFile = _path == (String*)0 ? String.withCString("(hardcoded)") : _path.lastPathComponent();
        String* d = String.withFormat("# %s — %s\n#\n", lnkFile.cString(),
                              _name == (String*)0 ? "unknown" : _name.cString());

        _rs = new Array(); _re = new Array(); _rl = new Array();
        if (_zpSPStart != (u32)0 || _zpSPEnd != (u32)0)
            region(_zpSPStart, _zpSPEnd, String.withCString("xtc ZP: SP"));
        if (_zpTmpStart != (u32)0 || _zpTmpEnd != (u32)0)
            region(_zpTmpStart, _zpTmpEnd, String.withCString("xtc ZP: tmp"));
        if (_zpHPStart != (u32)0 || _zpHPEnd != (u32)0)
            region(_zpHPStart, _zpHPEnd, String.withCString("xtc ZP: HP"));
        if (_zpRuntimeStart != (u32)0 || _zpRuntimeEnd != (u32)0)
            region(_zpRuntimeStart, _zpRuntimeEnd, String.withCString("runtime params (reserved)"));
        if (_hasSplit) {
            String* c = String.withCString("code bank selector (");
            c.append(range4(_codeWindowStart, _codeWindowEnd)); c.appendCString(")");
            region(_codeBankReg, _codeBankReg, c);
            String* dd = String.withCString("data bank selector (");
            dd.append(range4(_dataWindowStart, _dataWindowEnd)); dd.appendCString(")");
            region(_dataBankReg, _dataBankReg, dd);
        } else if (_zpBankRegStart != (u32)0 || _zpBankRegEnd != (u32)0) {
            region(_zpBankRegStart, _zpBankRegEnd, String.withCString("bank-select register"));
        }
        if (_hasRegionC && _regCBankRegLo != (u32)0) {
            u32 hi = _regCBankRegHi != (u32)0 ? _regCBankRegHi : _regCBankRegLo;
            String* l = String.withCString("region-C bank selector (");
            l.append(range4(_regCWindowStart, _regCWindowEnd)); l.appendCString(")");
            region(_regCBankRegLo, hi, l);
        }
        for (u32 i = (u32)0; _zpVars != (Array*)0 && i + (u32)1 < _zpVars.count(); i = i + (u32)2)
            region(((Number*)_zpVars.get(i)).asU32(), ((Number*)_zpVars.get(i + (u32)1)).asU32(),
                   String.withCString("xtc ZP: vars"));
        for (u32 i = (u32)0; _mainRanges != (Array*)0 && i + (u32)1 < _mainRanges.count(); i = i + (u32)2)
            region(((Number*)_mainRanges.get(i)).asU32(), ((Number*)_mainRanges.get(i + (u32)1)).asU32(),
                   String.withCString("Main region"));
        if (_systemStart != (u32)0 || _systemEnd != (u32)0)
            region(_systemStart, _systemEnd, String.withCString("System region"));
        if (_screenStart != (u32)0 || _screenEnd != (u32)0)
            region(_screenStart, _screenEnd, String.withCString("Screen RAM"));
        if (_hasBanking && _hasSplit) {
            String* c = String.withCString("Code bank window (via $");
            c.append(hex(_codeBankReg, (u32)2)); c.appendCString(")");
            region(_codeWindowStart, _codeWindowEnd, c);
            String* dd = String.withCString("Data bank window (via $");
            dd.append(hex(_dataBankReg, (u32)2)); dd.appendCString(")");
            region(_dataWindowStart, _dataWindowEnd, dd);
        }
        if (_hasRegionC) {
            String* l = String.withCString("Region C bank window (via $");
            l.append(hex(_regCBankRegLo, (u32)2));
            if (_regCBankRegHi != (u32)0) { l.appendCString("/$"); l.append(hex(_regCBankRegHi, (u32)2)); }
            l.appendCString(")");
            region(_regCWindowStart, _regCWindowEnd, l);
        }
        if (_hasBanking && !_hasSplit) {
            String* l = String.withCString("Bank window");
            if (_bankRegs != (Array*)0 && _bankRegs.count() >= (u32)2) {
                u32 addr = ((Number*)_bankRegs.get((u32)0)).asU32();
                u32 mask = ((Number*)_bankRegs.get((u32)1)).asU32();
                l = String.withCString("Bank window (via $");
                if (addr > (u32)$FF) {
                    l.append(hex(addr, (u32)4)); l.appendCString(":$"); l.append(hex(mask & (u32)$FF, (u32)2));
                } else {
                    l.append(hex(addr & (u32)$FF, (u32)2));
                }
                l.appendCString(")");
            }
            region(_bankWindowStart, _bankWindowEnd, l);
        }
        if (_hasShadow && _trampolineStart != (u32)0)
            region(_trampolineStart, _trampolineEnd, String.withCString("NMI/IRQ trampoline stub"));

        u32 box = (u32)50;
        String* bar = repeat("─", box);
        String* top = String.withCString("# ┌"); top.append(bar); top.appendCString("┐\n");
        String* sep = String.withCString("# ├"); sep.append(bar); sep.appendCString("┤\n");
        String* bot = String.withCString("# └"); bot.append(bar); bot.appendCString("┘\n");

        bool stackDone = false;
        d.append(top);
        for (u32 i = (u32)0; i < _rs.count(); i = i + (u32)1) {
            String* label = (String*)_rl.get(i);
            String* content = String.withCString(" ");
            content.append(range4(((Number*)_rs.get(i)).asU32(), ((Number*)_re.get(i)).asU32()));
            content.appendCString("  ");
            content.append(label);
            u32 len = units(content);
            u32 pad = len < box ? box - len : (u32)0;
            d.appendCString("# │");
            d.append(content);
            d.append(repeat(" ", pad));
            d.appendCString("│\n");

            // The stack and heap notes go once, on the system region if there
            // is one and on the first main region otherwise.
            bool home = !stackDone && (label.hasPrefix(String.withCString("System region"))
                        || (label.equals(String.withCString("Main region")) && _systemStart == (u32)0));
            if (home) {
                stackDone = true;
                String* si = String.withCString("   Stack ↑ ");
                if (_stackBase != (String*)0 && (_stackBase.equals(String.withCString("after-code"))
                                                 || _stackBase.equals(String.withCString("after-system")))) {
                    si.appendCString("("); si.append(_stackBase); si.appendCString(")");
                } else {
                    si.appendCString("(from ");
                    si.append(_stackBase == (String*)0 ? String.withCString("?") : _stackBase);
                    si.appendCString(")");
                }
                u32 sl = units(si);
                d.appendCString("# │");
                d.append(si);
                d.appendCString(" ");
                d.append(repeat(" ", sl + (u32)1 < box ? box - sl - (u32)1 : (u32)0));
                d.appendCString("│\n");
                String* hi = String.withCString("   $");
                hi.append(hex(_heapTop, (u32)4));
                hi.appendCString("  Heap ↓ (grows down)");
                u32 hl = units(hi);
                d.appendCString("# │");
                d.append(hi);
                d.appendCString(" ");
                d.append(repeat(" ", hl + (u32)1 < box ? box - hl - (u32)1 : (u32)0));
                d.appendCString("│\n");
            }
            if (i + (u32)1 < _rs.count()) d.append(sep);
        }
        d.append(bot);

        d.appendCString("#\n");
        // xl: no banking; xe: one PORTB-style register with a bit mask; xt:
        // everything else.
        bool xe = _hasBanking && !_hasSplit && _bankRegs != (Array*)0 && _bankRegs.count() == (u32)2
                  && ((Number*)_bankRegs.get((u32)1)).asU32() != (u32)$FF;
        bool xt = _hasBanking && !xe;
        if (_hasBanking)
            d.appendCString(xe ? "# Banking: PORTB.\n" : "# Banking: ZP pair.\n");
        if (xt && !_hasSplit) {
            d.appendCString("#\n");
            d.appendCString("# xt architectural intent: two independent 8 KB bank windows.\n");
            d.appendCString("#   $82 selects $4000-$5FFF (code half)\n");
            d.appendCString("#   $83 selects $6000-$7FFF (data half)\n");
            d.appendCString("# Current implementation uses a single 16 KB window via $82,\n");
            d.appendCString("# with $83 pinned to 0. The split is a deferred xt-fast-path\n");
            d.appendCString("# optimisation; the codegen, page tracker, simulator, and xta\n");
            d.appendCString("# all need updates before code can depend on $83 addressing\n");
            d.appendCString("# a different bank than $82.\n");
        } else if (_hasSplit) {
            u32 codeKB = (_codeWindowEnd - _codeWindowStart + (u32)1) / (u32)1024;
            u32 dataKB = (_dataWindowEnd - _dataWindowStart + (u32)1) / (u32)1024;
            u32 codeSpan = _codeRegionSpan != (u32)0 ? _codeRegionSpan
                         : (_codeWindowEnd - _codeWindowStart + (u32)1) * (u32)256;
            u32 dataSpan = _dataRegionSpan != (u32)0 ? _dataRegionSpan
                         : (_dataWindowEnd - _dataWindowStart + (u32)1) * (u32)256;
            d.appendCString("#\n");
            d.appendCString("# xt: independent bank windows.\n");
            d.appendCString("#   $"); d.append(hex(_codeBankReg, (u32)2));
            d.appendCString("      selects "); d.append(range4(_codeWindowStart, _codeWindowEnd));
            d.appendCString(" ("); d.append(dec(codeKB)); d.appendCString(" KB code),    ");
            d.append(spanLabel(codeSpan)); d.appendCString("\n");
            d.appendCString("#   $"); d.append(hex(_dataBankReg, (u32)2));
            d.appendCString("      selects "); d.append(range4(_dataWindowStart, _dataWindowEnd));
            d.appendCString(" ("); d.append(dec(dataKB)); d.appendCString(" KB data),    ");
            d.append(spanLabel(dataSpan)); d.appendCString("\n");
            if (_hasRegionC) {
                u32 regCKB = (_regCWindowEnd - _regCWindowStart + (u32)1) / (u32)1024;
                String* regCSpan = _regCRegionSpan != (u32)0 ? spanLabel(_regCRegionSpan)
                                                             : String.withCString("span unset");
                if (_regCBankRegHi != (u32)0) {
                    d.appendCString("#   $"); d.append(hex(_regCBankRegLo, (u32)2));
                    d.appendCString("/$"); d.append(hex(_regCBankRegHi, (u32)2));
                    d.appendCString("  selects ");
                } else {
                    d.appendCString("#   $"); d.append(hex(_regCBankRegLo, (u32)2));
                    d.appendCString("      selects ");
                }
                d.append(range4(_regCWindowStart, _regCWindowEnd));
                d.appendCString(" ("); d.append(dec(regCKB)); d.appendCString(" KB regionC), ");
                d.append(regCSpan); d.appendCString("\n");
                d.appendCString(_regCBankRegHi != (u32)0
                                ? "#             (16-bit pair, conditionally reserved)\n"
                                : "#             (conditionally reserved)\n");
            }
            if (_hasRegionC && _regCBankRegLo != (u32)0) {
                d.appendCString("# $"); d.append(hex(_dataBankReg, (u32)2));
                d.appendCString(" and $"); d.append(hex(_regCBankRegLo, (u32)2));
                if (_regCBankRegHi != (u32)0) { d.appendCString("/$"); d.append(hex(_regCBankRegHi, (u32)2)); }
                d.appendCString(" are callee-saved; _xcall swaps $"); d.append(hex(_codeBankReg, (u32)2));
                d.appendCString(" only.\n");
            } else {
                d.appendCString("# $"); d.append(hex(_dataBankReg, (u32)2));
                d.appendCString(" is callee-saved; _xcall swaps $"); d.append(hex(_codeBankReg, (u32)2));
                d.appendCString(" only.\n");
            }
        }
        if (_hasShadow) {
            d.appendCString("# Shadow mode: $"); d.append(hex(_shadowRegAddr, (u32)4));
            d.appendCString(":$"); d.append(hex(_shadowRegMask, (u32)2)); d.appendCString(".\n");
        }
        if (_entryAddress != (u32)0) {
            d.appendCString("# Entry: $"); d.append(hex(_entryAddress, (u32)4)); d.appendCString("\n");
        }
        return d;
    }
}
