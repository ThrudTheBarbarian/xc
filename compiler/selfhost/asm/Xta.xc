// Xta.xc — the banked-6502 assembler, in xtc.
// =================================================================
//
// self-hosting M24, a port of `XAAssembler`. Two passes over the source, with
// size-changing rewrites in between: pass 1 assigns label addresses, the
// long-branch and cross-bank rewriters may change instruction lengths, and the
// whole thing re-runs until the line list stops moving. Then pass 2 resolves
// every expression and emits bytes into origin-tagged segments, which the XEX
// writer turns into a loadable Atari binary.
//
// Two things here have no equivalent in the other assemblers.
//
// The 6502's conditional branches reach +/-127 bytes and nothing further, so an
// out-of-range branch is REWRITTEN as its inverse over a JMP. That changes the
// instruction's length, which moves every label after it — hence the iteration
// to a fixpoint rather than a single sizing pass.
//
// And code lives in declared REGIONS with hardware in the gaps between them. An
// instruction that would cross a region boundary is bridged: a JMP into the next
// region, or just a `.org` when the preceding instruction was an unconditional
// transfer and nothing falls through.
//
// The diagnostics, the platform symbol table, the listing and the PRG, XEX and
// banked-XEX writers follow the reference word for word: xcc-as is this file
// plus a command line, and a user sees the same messages either way.

#import "Foundation.xc"
#import "Files.xc"
#import "Stdio.xc"
#import "Xa6502.xc"

#define LT_EMPTY 0
#define LT_LABEL 1
#define LT_INSTRUCTION 2
#define LT_ASSIGNMENT 3
#define LT_ORG 4
#define LT_BYTE 5
#define LT_WORD 6
#define LT_LONG 7
#define LT_STRING 8
#define LT_SPACE 9
#define LT_CODE_REGIONS 10
#define LT_BANK 11
#define LT_SPILL_POINT 12
#define LT_SHADOW_RANGES 13
#define LT_SHADOW_STAGE 14
#define LT_CLOAKED_BEGIN 15
#define LT_CLOAKED_END 16

class XaLine
    {
    u32 _type;
    String* _label;
    bool _labelIsLocal;
    String* _mnemonic;
    String* _operand;
    u32 _mode;
    u32 _byteSize;
    u32 _address;
    Array* _dataValues; // String@ per element
    String* _assignName;
    String* _assignValue;
    String* _rawText;
    u32 _sourceLine;
    bool _isLongbrInverse;

    void init(void)
        {
        _type = (u32)LT_EMPTY;
        _labelIsLocal = false;
        _mode = (u32)AM_IMPLIED;
        _byteSize = (u32)0;
        _address = (u32)0;
        _sourceLine = (u32)0;
        _isLongbrInverse = false;
        }

    u32 type(void)
        {
        return _type;
        }
    String* label(void)
        {
        return _label;
        }
    bool labelIsLocal(void)
        {
        return _labelIsLocal;
        }
    String* mnemonic(void)
        {
        return _mnemonic;
        }
    String* operand(void)
        {
        return _operand;
        }
    u32 mode(void)
        {
        return _mode;
        }
    u32 byteSize(void)
        {
        return _byteSize;
        }
    u32 address(void)
        {
        return _address;
        }
    Array* dataValues(void)
        {
        return _dataValues;
        }
    String* assignName(void)
        {
        return _assignName;
        }
    String* assignValue(void)
        {
        return _assignValue;
        }
    String* rawText(void)
        {
        return _rawText;
        }
    u32 sourceLine(void)
        {
        return _sourceLine;
        }
    bool isLongbrInverse(void)
        {
        return _isLongbrInverse;
        }

    void setType(u32 v)
        {
        _type = v;
        }
    void setLabel(String* v)
        {
        _label = v;
        }
    void setLabelIsLocal(bool v)
        {
        _labelIsLocal = v;
        }
    void setMnemonic(String* v)
        {
        _mnemonic = v;
        }
    void setOperand(String* v)
        {
        _operand = v;
        }
    void setMode(u32 v)
        {
        _mode = v;
        }
    void setByteSize(u32 v)
        {
        _byteSize = v;
        }
    void setAddress(u32 v)
        {
        _address = v;
        }
    void setDataValues(Array* v)
        {
        _dataValues = v;
        }
    void setAssign(String* n, String* v)
        {
        _assignName = n;
        _assignValue = v;
        }
    void setRawText(String* v)
        {
        _rawText = v;
        }
    void setSourceLine(u32 v)
        {
        _sourceLine = v;
        }
    void setLongbrInverse(bool v)
        {
        _isLongbrInverse = v;
        }
    }

// A contiguous block of assembled bytes at a load origin.
class XaSegment
    {
    u32 _origin;
    Array* _data; // Number@ per byte
    // A `.bank <id>` segment carries an EXPLICIT bank number, allocated so it
    // cannot clash with the encounter-order user banks. -1 means "use the
    // running counter" — a plain `.org` into the window.
    i32 _bankNumber;
    // A `.cloaked_segment` block. Its bank index is -1 for "banking off".
    bool _isCloaked;
    i32 _cloakedBankIndex;

    void init(void)
        {
        _origin = (u32)0;
        _data = new Array();
        _bankNumber = (i32)-1;
        _isCloaked = false;
        _cloakedBankIndex = (i32)-1;
        }

    i32 bankNumber(void)
        {
        return _bankNumber;
        }
    void setBankNumber(i32 v)
        {
        _bankNumber = v;
        }
    bool isCloaked(void)
        {
        return _isCloaked;
        }
    void setCloaked(bool v)
        {
        _isCloaked = v;
        }
    i32 cloakedBankIndex(void)
        {
        return _cloakedBankIndex;
        }
    void setCloakedBankIndex(i32 v)
        {
        _cloakedBankIndex = v;
        }

    static XaSegment* at(u32 origin)
        {
        XaSegment* s = new XaSegment();
        s._origin = origin;
        return s;
        }

    u32 origin(void)
        {
        return _origin;
        }
    Array* data(void)
        {
        return _data;
        }
    void setOrigin(u32 v)
        {
        _origin = v;
        }
    }

// Text helpers shared by the assembler and the xcc-as command line. They
// reproduce the host-library behaviour the reference leans on: its trimming
// removes spaces and tabs only (a CR survives), and its numeric literals parse
// the way the C library's strtoull does.
class XaText
    {
    u8 _unused;

    void init(void)
        {
        _unused = (u8)0;
        }

    static bool isWs(u8 c)
        {
        return c == (u8)' ' || c == (u8)'\t';
        }
    static bool isWsNl(u8 c)
        {
        return c == (u8)' ' || c == (u8)'\t' || c == (u8)'\n' || c == (u8)'\r' || c == (u8)11 || c == (u8)12;
        }

    // Trim spaces and tabs.
    static String* tws(String* s)
        {
        if (s == (String*)0)
            return s;
        u32 lo = (u32)0;
        u32 n = s.byteLength();
        while (lo < n && XaText.isWs(s.byteAt(lo)))
            lo = lo + (u32)1;
        u32 hi = n;
        while (hi > lo && XaText.isWs(s.byteAt(hi - (u32)1)))
            hi = hi - (u32)1;
        return s.substringBytes(lo, hi - lo);
        }

    // Trim spaces, tabs and line ends.
    static String* twsn(String* s)
        {
        if (s == (String*)0)
            return s;
        u32 lo = (u32)0;
        u32 n = s.byteLength();
        while (lo < n && XaText.isWsNl(s.byteAt(lo)))
            lo = lo + (u32)1;
        u32 hi = n;
        while (hi > lo && XaText.isWsNl(s.byteAt(hi - (u32)1)))
            hi = hi - (u32)1;
        return s.substringBytes(lo, hi - lo);
        }

    static i32 hexDigit(u8 c)
        {
        if (c >= (u8)'0' && c <= (u8)'9')
            return (i32)(c - (u8)'0');
        if (c >= (u8)'a' && c <= (u8)'f')
            return (i32)(c - (u8)'a') + (i32)10;
        if (c >= (u8)'A' && c <= (u8)'F')
            return (i32)(c - (u8)'A') + (i32)10;
        return (i32)-1;
        }

    // strtoull(s, NULL, base) as an i64: leading white space, an optional sign,
    // an optional 0x for base 16, then as many digits as there are. Overflow
    // saturates, as the C library does.
    static i64 strtoull(String* s, u32 base)
        {
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
        if (base == (u32)16 && i + (u32)2 < n && s.byteAt(i) == (u8)'0' && (s.byteAt(i + (u32)1) == (u8)'x' || s.byteAt(i + (u32)1) == (u8)'X') && XaText.hexDigit(s.byteAt(i + (u32)2)) >= (i32)0)
            i = i + (u32)2;
        u64 v = (u64)0;
        bool over = false;
        bool any = false;
        while (i < n)
            {
            i32 d = XaText.hexDigit(s.byteAt(i));
            if (d < (i32)0 || (u32)d >= base)
                break;
            any = true;
            u64 limit = ((u64)$FFFF_FFFF_FFFF_FFFF - (u64)d) / (u64)base;
            if (v > limit)
                over = true;
            else
                v = v * (u64)base + (u64)d;
            i = i + (u32)1;
            }
        if (!any)
            return (i64)0;
        if (over)
            return (i64)-1;
        if (neg)
            v = (u64)0 - v;
        return (i64)v;
        }

    // strtoll(s, NULL, 10) over a string already known to be all digits.
    static i64 strtoll10(String* s)
        {
        u64 v = (u64)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u64 d = (u64)(s.byteAt(i) - (u8)'0');
            if (v > ((u64)$7FFF_FFFF_FFFF_FFFF - d) / (u64)10)
                return (i64)$7FFF_FFFF_FFFF_FFFF;
            v = v * (u64)10 + d;
            }
        return (i64)v;
        }

    // NSScanner scanHexInt: white space, an optional 0x, at least one digit;
    // true and the value (UINT_MAX on overflow), and where it stopped.
    static bool scanHex(String* s, u32* value, u32* end)
        {
        u32 n = s.byteLength();
        u32 i = (u32)0;
        while (i < n && XaText.isWsNl(s.byteAt(i)))
            i = i + (u32)1;
        if (i + (u32)2 < n && s.byteAt(i) == (u8)'0' && (s.byteAt(i + (u32)1) == (u8)'x' || s.byteAt(i + (u32)1) == (u8)'X') && XaText.hexDigit(s.byteAt(i + (u32)2)) >= (i32)0)
            i = i + (u32)2;
        u64 v = (u64)0;
        bool any = false;
        while (i < n && XaText.hexDigit(s.byteAt(i)) >= (i32)0)
            {
            any = true;
            v = v * (u64)16 + (u64)XaText.hexDigit(s.byteAt(i));
            if (v > (u64)$FFFF_FFFF)
                v = (u64)$1_0000_0000;
            i = i + (u32)1;
            }
        if (!any)
            return false;
        *value = v > (u64)$FFFF_FFFF ? (u32)$FFFF_FFFF : (u32)v;
        *end = i;
        return true;
        }

    // NSScanner isAtEnd: only skippable white space remains.
    static bool restIsWs(String* s, u32 from)
        {
        for (u32 i = from; i < s.byteLength(); i = i + (u32)1)
            if (!XaText.isWsNl(s.byteAt(i)))
                return false;
        return true;
        }

    // `%0NX` over an unsigned 64-bit value.
    static String* hex(u64 v, u32 minDigits)
        {
        String* digits = new String();
        u64 x = v;
        while (x != (u64)0)
            {
            u32 nib = (u32)(x & (u64)$F);
            digits.appendByte(nib < (u32)10 ? (u8)((u32)'0' + nib) : (u8)((u32)'A' + nib - (u32)10));
            x = x >> (u64)4;
            }
        while (digits.byteLength() < minDigits)
            digits.appendByte((u8)'0');
        String* out = new String();
        u32 k = digits.byteLength();
        while (k > (u32)0)
            {
            k = k - (u32)1;
            out.appendByte(digits.byteAt(k));
            }
        return out;
        }

    static String* hex4(u32 v)
        {
        return XaText.hex((u64)v, (u32)4);
        }

    static String* dec(i64 v)
        {
        return String.withI64(v);
        }

    static String* udec(u64 v)
        {
        return String.withU64(v);
        }

    // NSString -length of UTF-8 text: one unit per character, two for one
    // outside the basic plane.
    static u32 utf16Length(String* s)
        {
        u32 n = (u32)0;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if ((c & (u8)$C0) == (u8)$80)
                continue;
            n = n + (u32)1;
            if (c >= (u8)$F0)
                n = n + (u32)1;
            }
        return n;
        }

    // Whether the bytes are well-formed UTF-8, as the reference's text reads
    // demand of every file they open.
    static bool isUtf8(String* s)
        {
        u32 n = s.byteLength();
        u32 i = (u32)0;
        while (i < n)
            {
            u8 c = s.byteAt(i);
            if (c < (u8)$80)
                {
                i = i + (u32)1;
                continue;
                }
            u32 need = (u32)0;
            u32 cp = (u32)0;
            if (c >= (u8)$C2 && c <= (u8)$DF)
                {
                need = (u32)1;
                cp = (u32)(c & (u8)$1F);
                }
            else if (c >= (u8)$E0 && c <= (u8)$EF)
                {
                need = (u32)2;
                cp = (u32)(c & (u8)$0F);
                }
            else if (c >= (u8)$F0 && c <= (u8)$F4)
                {
                need = (u32)3;
                cp = (u32)(c & (u8)$07);
                }
            else
                return false;
            if (i + need >= n)
                return false;
            for (u32 k = (u32)1; k <= need; k = k + (u32)1)
                {
                u8 cc = s.byteAt(i + k);
                if ((cc & (u8)$C0) != (u8)$80)
                    return false;
                cp = (cp << (u32)6) | (u32)(cc & (u8)$3F);
                }
            if (need == (u32)2 && (cp < (u32)$800 || (cp >= (u32)$D800 && cp <= (u32)$DFFF)))
                return false;
            if (need == (u32)3 && (cp < (u32)$10000 || cp > (u32)$10FFFF))
                return false;
            i = i + need + (u32)1;
            }
        return true;
        }
    }

class Xta
    {
    Xa6502* _cpu;
    Map* _symbols;  // name -> Number (i64)
    Array* _lines;  // XaLine@
    Array* _errors; // String@
    Array* _warnings;
    u32 _pc;
    String* _lastGlobalLabel;
    Array* _codeRegions; // pairs of Number@: lo, hi
    u32 _currentRegionIndex;
    bool _pcInsideMainRegion;
    bool _finalRegionOverflowReported;
    bool _inCloakedSegment;
    u32 _codeBankReg;
    u32 _dataBankReg;
    Array* _segments; // XaSegment@
    Map* _bankIds;    // `.bank` identifier -> its physical bank number
    Map* _labelBank;  // label -> the bank it is defined in
    Map* _ambiguousWarned;
    Array* _shadowRanges; // pairs of Number@: lo, hi
    u32 _shadowStageBase;
    String* _filename;
    bool _verbose;
    Map* _platformSymbols;
    Array* _symbolsFiles; // String@
    String* _symbolsFile;
    Map* _predefines;     // -D name -> Number
    u32 _mainRegionStart;
    u32 _mainRegionEnd;
    u32 _regCWindowStart;
    u32 _regCWindowEnd;
    u32 _regCBankRegLo;
    u32 _regCBankRegHi;

    void init(void)
        {
        _cpu = new Xa6502();
        _symbols = new Map();
        _lines = new Array();
        _errors = new Array();
        _warnings = new Array();
        _segments = new Array();
        _ambiguousWarned = new Map();
        _predefines = new Map();
        _codeBankReg = (u32)0;
        _dataBankReg = (u32)0;
        _shadowStageBase = (u32)0;
        _filename = String.withCString("");
        _verbose = false;
        }

    void setBankRegs(u32 code, u32 data)
        {
        _codeBankReg = code;
        _dataBankReg = data;
        }
    void setFilename(String* f)
        {
        _filename = f;
        }
    void setVerbose(bool v)
        {
        _verbose = v;
        }
    void setSymbolsFile(String* f)
        {
        _symbolsFile = f;
        }
    void setSymbolsFiles(Array* files)
        {
        _symbolsFiles = files;
        }
    void setMainRegion(u32 lo, u32 hi)
        {
        _mainRegionStart = lo;
        _mainRegionEnd = hi;
        }
    void setRegionC(u32 lo, u32 hi, u32 regLo, u32 regHi)
        {
        _regCWindowStart = lo;
        _regCWindowEnd = hi;
        _regCBankRegLo = regLo;
        _regCBankRegHi = regHi;
        }

    Array* errors(void)
        {
        return _errors;
        }
    Array* warnings(void)
        {
        return _warnings;
        }
    Array* segments(void)
        {
        return _segments;
        }
    Map* symbols(void)
        {
        return _symbols;
        }

    void err(String* m)
        {
        _errors.add((Object*)m);
        }
    void warn(String* m)
        {
        _warnings.add((Object*)m);
        }

    // `<file>:<line>: ` — the prefix pass 1's diagnostics carry.
    String* where(u32 line)
        {
        String* m = String.withString(_filename);
        m.appendCString(":");
        m.append(String.withU32(line));
        m.appendCString(": ");
        return m;
        }

    // ── Predefined symbols ───────────────────────────────────────────────
    //
    // -D NAME[=VALUE]. The value is evaluated now, against an empty table, and
    // the result is laid over the platform symbols at the start of every pass.
    void defineSymbol(String* name, String* value)
        {
        _predefines.set((Hashable*)name, (Object*)Number.withI64(evaluate(value)));
        }

    // The platform symbol table: every `.sym` file named, merged in order with
    // later entries winning, and the built-in Atari map when none of them
    // yielded anything.
    Map* platformSymbols(void)
        {
        if (_platformSymbols != (Map*)0)
            return _platformSymbols;
        Map* merged = new Map();
        bool fileListed = false;
        if (_symbolsFiles != (Array*)0)
            for (u32 i = (u32)0; i < _symbolsFiles.count(); i = i + (u32)1)
                {
                String* p = (String*)_symbolsFiles.get(i);
                if (p.byteLength() == (u32)0)
                    continue;
                if (_symbolsFile != (String*)0 && p.equals(_symbolsFile))
                    fileListed = true;
                mergeInto(merged, Xta.loadSymbols(p));
                }
        if (_symbolsFile != (String*)0 && _symbolsFile.byteLength() > (u32)0 && !fileListed)
            mergeInto(merged, Xta.loadSymbols(_symbolsFile));
        if (merged.allKeys().count() == (u32)0)
            merged = Xta.atariMemoryMap();
        _platformSymbols = merged;
        return merged;
        }

    static void mergeInto(Map* dst, Map* src)
        {
        Array* keys = src.allKeys();
        for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1)
            {
            Hashable* k = (Hashable*)keys.get(i);
            dst.set(k, src.get(k));
            }
        }

    // A `.sym` file: `NAME = $XXXX` per line, `;` comments.
    static Map* loadSymbols(String* path)
        {
        Map* syms = new Map();
        String* text = Files.readText(path);
        if (text == (String*)0 || !XaText.isUtf8(text))
            return syms;
        Array* lines = text.splitOnByte((u8)'\n');
        for (u32 i = (u32)0; i < lines.count(); i = i + (u32)1)
            {
            String* line = (String*)lines.get(i);
            u32 semi = line.indexOfByte((u8)';');
            if (semi != (u32)$FFFF_FFFF)
                line = line.substringBytes((u32)0, semi);
            line = XaText.twsn(line);
            if (line.byteLength() == (u32)0)
                continue;
            u32 eq = line.indexOfByte((u8)'=');
            if (eq == (u32)$FFFF_FFFF)
                continue;
            String* name = XaText.tws(line.substringBytes((u32)0, eq));
            String* val = XaText.tws(line.substringFromByte(eq + (u32)1));
            if (val.hasPrefix(String.withCString("$")))
                {
                u32 v = (u32)0;
                u32 end = (u32)0;
                if (XaText.scanHex(val.substringFromByte((u32)1), &v, &end))
                    syms.set((Hashable*)name, (Object*)Number.withI64((i64)v));
                }
            }
        return syms;
        }

    static void sym(Map* m, string name, u32 v)
        {
        m.set((Hashable*)String.withCString(name), (Object*)Number.withI64((i64)v));
        }

    // The Atari memory map the reference falls back to when no symbol file is
    // loaded — the table a program gets from the compiler, which names none.
    static Map* atariMemoryMap(void)
        {
        Map* m = new Map();
        Xta.sym(m, "LINZBS", (u32)$00);
        Xta.sym(m, "CASINI", (u32)$02);
        Xta.sym(m, "RAMLO", (u32)$04);
        Xta.sym(m, "TRAMSZ", (u32)$06);
        Xta.sym(m, "TSTDAT", (u32)$07);
        Xta.sym(m, "WARMST", (u32)$08);
        Xta.sym(m, "BOOTQ", (u32)$09);
        Xta.sym(m, "DOSVEC", (u32)$0A);
        Xta.sym(m, "DOSINI", (u32)$0C);
        Xta.sym(m, "APPMHI", (u32)$0E);
        Xta.sym(m, "POKMSK", (u32)$10);
        Xta.sym(m, "BRKKEY", (u32)$11);
        Xta.sym(m, "RTCLOK", (u32)$12);
        Xta.sym(m, "BUFADR", (u32)$15);
        Xta.sym(m, "ICCOMT", (u32)$17);
        Xta.sym(m, "DTEFIL", (u32)$1A);
        Xta.sym(m, "ICCMD", (u32)$1B);
        Xta.sym(m, "DTEFLI", (u32)$1C);
        Xta.sym(m, "LBUFF", (u32)$1D);
        Xta.sym(m, "SSKCTL", (u32)$4E);
        Xta.sym(m, "VDSLST", (u32)$200);
        Xta.sym(m, "VPRCED", (u32)$202);
        Xta.sym(m, "VINTER", (u32)$204);
        Xta.sym(m, "VBREAK", (u32)$206);
        Xta.sym(m, "VKEYBD", (u32)$208);
        Xta.sym(m, "VSERIN", (u32)$20A);
        Xta.sym(m, "VSEROC", (u32)$20C);
        Xta.sym(m, "VTIMR1", (u32)$210);
        Xta.sym(m, "VTIMR2", (u32)$212);
        Xta.sym(m, "VTIMR4", (u32)$214);
        Xta.sym(m, "VIMIRQ", (u32)$216);
        Xta.sym(m, "CDTMV1", (u32)$218);
        Xta.sym(m, "CDTMV2", (u32)$21A);
        Xta.sym(m, "CDTMV3", (u32)$21C);
        Xta.sym(m, "CDTMV4", (u32)$21E);
        Xta.sym(m, "CDTMV5", (u32)$220);
        Xta.sym(m, "SDMCTL", (u32)$22F);
        Xta.sym(m, "SDLSTL", (u32)$230);
        Xta.sym(m, "SDLSTH", (u32)$231);
        Xta.sym(m, "LPENH", (u32)$234);
        Xta.sym(m, "LPENV", (u32)$235);
        Xta.sym(m, "TXTROW", (u32)$290);
        Xta.sym(m, "TXTCOL", (u32)$291);
        Xta.sym(m, "DINDEX", (u32)$57);
        Xta.sym(m, "SAVMSC", (u32)$58);
        Xta.sym(m, "OLDROW", (u32)$5A);
        Xta.sym(m, "OLDCOL", (u32)$5B);
        Xta.sym(m, "OLDCHR", (u32)$5D);
        Xta.sym(m, "OLDADR", (u32)$5E);
        Xta.sym(m, "ROWCRS", (u32)$54);
        Xta.sym(m, "COLCRS", (u32)$55);
        Xta.sym(m, "LMARGN", (u32)$52);
        Xta.sym(m, "RMARGN", (u32)$53);
        Xta.sym(m, "LOGCOL", (u32)$63);
        Xta.sym(m, "ATACHR", (u32)$2FB);
        Xta.sym(m, "CH", (u32)$2FC);
        Xta.sym(m, "FILDAT", (u32)$2FD);
        Xta.sym(m, "DSPFLG", (u32)$2FE);
        Xta.sym(m, "SSFLAG", (u32)$2FF);
        Xta.sym(m, "PCOLR0", (u32)$2C0);
        Xta.sym(m, "PCOLR1", (u32)$2C1);
        Xta.sym(m, "PCOLR2", (u32)$2C2);
        Xta.sym(m, "PCOLR3", (u32)$2C3);
        Xta.sym(m, "COLOR0", (u32)$2C4);
        Xta.sym(m, "COLOR1", (u32)$2C5);
        Xta.sym(m, "COLOR2", (u32)$2C6);
        Xta.sym(m, "COLOR3", (u32)$2C7);
        Xta.sym(m, "COLOR4", (u32)$2C8);
        Xta.sym(m, "COLPF0", (u32)$D016);
        Xta.sym(m, "COLPF1", (u32)$D017);
        Xta.sym(m, "COLPF2", (u32)$D018);
        Xta.sym(m, "COLPF3", (u32)$D019);
        Xta.sym(m, "COLBK", (u32)$D01A);
        Xta.sym(m, "COLPM0", (u32)$D012);
        Xta.sym(m, "COLPM1", (u32)$D013);
        Xta.sym(m, "COLPM2", (u32)$D014);
        Xta.sym(m, "COLPM3", (u32)$D015);
        Xta.sym(m, "HPOSP0", (u32)$D000);
        Xta.sym(m, "HPOSP1", (u32)$D001);
        Xta.sym(m, "HPOSP2", (u32)$D002);
        Xta.sym(m, "HPOSP3", (u32)$D003);
        Xta.sym(m, "HPOSM0", (u32)$D004);
        Xta.sym(m, "HPOSM1", (u32)$D005);
        Xta.sym(m, "HPOSM2", (u32)$D006);
        Xta.sym(m, "HPOSM3", (u32)$D007);
        Xta.sym(m, "SIZEP0", (u32)$D008);
        Xta.sym(m, "SIZEP1", (u32)$D009);
        Xta.sym(m, "SIZEP2", (u32)$D00A);
        Xta.sym(m, "SIZEP3", (u32)$D00B);
        Xta.sym(m, "SIZEM", (u32)$D00C);
        Xta.sym(m, "GRAFP0", (u32)$D00D);
        Xta.sym(m, "GRAFP1", (u32)$D00E);
        Xta.sym(m, "GRAFP2", (u32)$D00F);
        Xta.sym(m, "GRAFP3", (u32)$D010);
        Xta.sym(m, "GRAFM", (u32)$D011);
        Xta.sym(m, "GRACTL", (u32)$D01D);
        Xta.sym(m, "HITCLR", (u32)$D01E);
        Xta.sym(m, "CONSOL", (u32)$D01F);
        Xta.sym(m, "PRIOR", (u32)$D01B);
        Xta.sym(m, "AUDF1", (u32)$D200);
        Xta.sym(m, "AUDC1", (u32)$D201);
        Xta.sym(m, "AUDF2", (u32)$D202);
        Xta.sym(m, "AUDC2", (u32)$D203);
        Xta.sym(m, "AUDF3", (u32)$D204);
        Xta.sym(m, "AUDC3", (u32)$D205);
        Xta.sym(m, "AUDF4", (u32)$D206);
        Xta.sym(m, "AUDC4", (u32)$D207);
        Xta.sym(m, "AUDCTL", (u32)$D208);
        Xta.sym(m, "STIMER", (u32)$D209);
        Xta.sym(m, "SKREST", (u32)$D20A);
        Xta.sym(m, "POTGO", (u32)$D20B);
        Xta.sym(m, "SEROUT", (u32)$D20D);
        Xta.sym(m, "IRQEN", (u32)$D20E);
        Xta.sym(m, "SKCTL", (u32)$D20F);
        Xta.sym(m, "SERIN", (u32)$D20D);
        Xta.sym(m, "IRQST", (u32)$D20E);
        Xta.sym(m, "SKSTAT", (u32)$D20F);
        Xta.sym(m, "KBCODE", (u32)$D209);
        Xta.sym(m, "RANDOM", (u32)$D20A);
        Xta.sym(m, "DMACTL", (u32)$D400);
        Xta.sym(m, "CHACTL", (u32)$D401);
        Xta.sym(m, "DLISTL", (u32)$D402);
        Xta.sym(m, "DLISTH", (u32)$D403);
        Xta.sym(m, "HSCROL", (u32)$D404);
        Xta.sym(m, "VSCROL", (u32)$D405);
        Xta.sym(m, "PMBASE", (u32)$D407);
        Xta.sym(m, "CHBASE", (u32)$D409);
        Xta.sym(m, "WSYNC", (u32)$D40A);
        Xta.sym(m, "VCOUNT", (u32)$D40B);
        Xta.sym(m, "PENH", (u32)$D40C);
        Xta.sym(m, "PENV", (u32)$D40D);
        Xta.sym(m, "NMIEN", (u32)$D40E);
        Xta.sym(m, "NMIST", (u32)$D40F);
        Xta.sym(m, "NMIRES", (u32)$D40F);
        Xta.sym(m, "PORTA", (u32)$D300);
        Xta.sym(m, "PORTB", (u32)$D301);
        Xta.sym(m, "PACTL", (u32)$D302);
        Xta.sym(m, "PBCTL", (u32)$D303);
        Xta.sym(m, "RUNAD", (u32)$02E0);
        Xta.sym(m, "INITAD", (u32)$02E2);
        Xta.sym(m, "CHBAS", (u32)$2F4);
        Xta.sym(m, "ATRACT", (u32)$4D);
        Xta.sym(m, "FR0", (u32)$D4);
        Xta.sym(m, "FR1", (u32)$E0);
        Xta.sym(m, "CIX", (u32)$F2);
        Xta.sym(m, "INBUFF", (u32)$F3);
        Xta.sym(m, "FLPTR", (u32)$FC);
        return m;
        }

    // ── Expression evaluation ────────────────────────────────────────────
    //
    // `<` and `>` take the low and high byte. Everything else is the usual
    // precedence-free right-split: the LAST top-level `+`/`-` splits first, so
    // evaluation is left-associative, and `*`/`/` bind tighter only because
    // they are looked for second.
    i64 evaluate(String* expr)
        {
        if (expr == (String*)0)
            return (i64)0;
        String* e = XaText.tws(expr);
        if (e.byteLength() == (u32)0)
            return (i64)0;

        if (e.hasPrefix(String.withCString("<")))
            return evaluate(e.substringFromByte((u32)1)) & (i64)$FF;
        if (e.hasPrefix(String.withCString(">")))
            return (evaluate(e.substringFromByte((u32)1)) >> (i64)8) & (i64)$FF;

        i32 parenDepth = (i32)0;
        i32 lastAddSub = (i32)-1;
        i32 lastMulDiv = (i32)-1;
        u32 i = e.byteLength();
        while (i > (u32)0)
            {
            i = i - (u32)1;
            u8 ch = e.byteAt(i);
            if (ch == (u8)')')
                parenDepth = parenDepth + (i32)1;
            else if (ch == (u8)'(')
                parenDepth = parenDepth - (i32)1;
            else if (parenDepth == (i32)0)
                {
                if ((ch == (u8)'+' || ch == (u8)'-') && i > (u32)0)
                    {
                    lastAddSub = (i32)i;
                    break;
                    }
                if ((ch == (u8)'*' || ch == (u8)'/') && i > (u32)0 && lastMulDiv < (i32)0)
                    lastMulDiv = (i32)i;
                }
            }
        if (lastAddSub > (i32)0)
            {
            i64 left = evaluate(e.substringBytes((u32)0, (u32)lastAddSub));
            u8 op = e.byteAt((u32)lastAddSub);
            i64 right = evaluate(e.substringFromByte((u32)lastAddSub + (u32)1));
            return op == (u8)'+' ? left + right : left - right;
            }
        if (lastMulDiv > (i32)0)
            {
            i64 left = evaluate(e.substringBytes((u32)0, (u32)lastMulDiv));
            u8 op = e.byteAt((u32)lastMulDiv);
            i64 right = evaluate(e.substringFromByte((u32)lastMulDiv + (u32)1));
            if (op == (u8)'*')
                return left * right;
            return right != (i64)0 ? left / right : (i64)0;
            }
        if (e.hasPrefix(String.withCString("(")) && e.hasSuffix(String.withCString(")")))
            return evaluate(e.substringBytes((u32)1, e.byteLength() - (u32)2));

        if (e.hasPrefix(String.withCString("$")))
            return XaText.strtoull(e.substringFromByte((u32)1), (u32)16);
        if (e.hasPrefix(String.withCString("%")))
            return XaText.strtoull(e.substringFromByte((u32)1), (u32)2);

        // A DEFINED symbol always wins over the Z80-style hex suffix, so a
        // pathological label like `0abch` — digit-first, all hex, trailing h,
        // and indistinguishable from a literal by any heuristic — resolves to
        // the label when one exists. It is worth a warning, once.
        Object* sym = _symbols.get((Hashable*)e);
        if (sym != (Object*)0)
            {
            if (isZ80Hex(e) && _ambiguousWarned.get((Hashable*)e) == (Object*)0)
                {
                _ambiguousWarned.set((Hashable*)e, (Object*)Number.withU32((u32)1));
                String* m = String.withCString("label '");
                m.append(e);
                m.appendCString("' is ambiguous with Z80-style hex literal; resolving to the label — rename it or use $");
                m.append(e.substringBytes((u32)0, e.byteLength() - (u32)1));
                m.appendCString(" to silence this warning");
                warn(m);
                }
            return ((Number*)sym).asI64();
            }

        if (isZ80Hex(e))
            return XaText.strtoull(e.substringBytes((u32)0, e.byteLength() - (u32)1), (u32)16);

        // A decimal literal needs EVERY character to be a digit. Checking only
        // the first made `12h_skip` evaluate to 12, because the C parse stops
        // at the `h`.
        if (allDigits(e))
            return XaText.strtoll10(e);

        // Then any symbol whose name matches ignoring case.
        Array* keys = _symbols.allKeys();
        for (u32 k = (u32)0; k < keys.count(); k = k + (u32)1)
            {
            String* key = (String*)keys.get(k);
            if (key.equalsIgnoringCase(e))
                return ((Number*)_symbols.get((Hashable*)key)).asI64();
            }

        String* m = String.withCString("undefined symbol '");
        m.append(e);
        m.appendCString("', using 0");
        warn(m);
        return (i64)0;
        }

    // Pass 1's zero-page test: -1 would be a real value, so an unresolvable
    // expression answers $100 — "assume not zero page".
    i64 tryEvaluate(String* expr)
        {
        if (expr == (String*)0)
            return (i64)-1;
        String* e = XaText.tws(expr);
        if (e.hasPrefix(String.withCString("$")))
            return XaText.strtoull(e.substringFromByte((u32)1), (u32)16);
        if (e.hasPrefix(String.withCString("%")))
            return XaText.strtoull(e.substringFromByte((u32)1), (u32)2);
        if (allDigits(e))
            return XaText.strtoll10(e);
        Object* sym = _symbols.get((Hashable*)e);
        if (sym != (Object*)0)
            return ((Number*)sym).asI64();
        return (i64)$100;
        }

    static bool allDigits(String* e)
        {
        if (e.byteLength() == (u32)0)
            return false;
        for (u32 i = (u32)0; i < e.byteLength(); i = i + (u32)1)
            {
            u8 c = e.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                return false;
            }
        return true;
        }

    static bool isZ80Hex(String* e)
        {
        if (e.byteLength() < (u32)2)
            return false;
        u8 last = e.byteAt(e.byteLength() - (u32)1);
        if (last != (u8)'h' && last != (u8)'H')
            return false;
        u8 first = e.byteAt((u32)0);
        if (first < (u8)'0' || first > (u8)'9')
            return false;
        for (u32 i = (u32)0; i + (u32)1 < e.byteLength(); i = i + (u32)1)
            if (XaText.hexDigit(e.byteAt(i)) < (i32)0)
                return false;
        return true;
        }

    static bool isValidIdentifier(String* s)
        {
        if (s.byteLength() == (u32)0)
            return false;
        u8 f = s.byteAt((u32)0);
        if (f == (u8)'>')
            return s.byteLength() > (u32)1;
        return (f >= (u8)'a' && f <= (u8)'z') || (f >= (u8)'A' && f <= (u8)'Z') || f == (u8)'_' || f == (u8)'.';
        }

    // ── Line handling ────────────────────────────────────────────────────
    //
    // A `;` outside a string starts a comment.
    static String* stripComment(String* line)
        {
        bool inString = false;
        for (u32 i = (u32)0; i < line.byteLength(); i = i + (u32)1)
            {
            u8 ch = line.byteAt(i);
            if (ch == (u8)'"')
                inString = !inString;
            if (ch == (u8)';' && !inString)
                return line.substringBytes((u32)0, i);
            }
        return line;
        }

    // The compound separator is " : " — a label's colon has no spaces around
    // it, so `_fn_main:` survives intact while `TXA : PHA` splits in two.
    static Array* splitCompoundLine(String* line)
        {
        Array* out = new Array();
        if (line.byteIndexOf(String.withCString(" : ")) == (u32)$FFFF_FFFF)
            {
            out.add((Object*)line);
            return out;
            }
        u32 start = (u32)0;
        u32 i = (u32)0;
        while (i + (u32)2 < line.byteLength())
            {
            if (line.byteAt(i) == (u8)' ' && line.byteAt(i + (u32)1) == (u8)':' && line.byteAt(i + (u32)2) == (u8)' ')
                {
                String* t = XaText.tws(line.substringBytes(start, i - start));
                if (t.byteLength() > (u32)0)
                    out.add((Object*)t);
                i = i + (u32)3;
                start = i;
                continue;
                }
            i = i + (u32)1;
            }
        String* t = XaText.tws(line.substringFromByte(start));
        if (t.byteLength() > (u32)0)
            out.add((Object*)t);
        if (out.count() == (u32)0)
            out.add((Object*)line);
        return out;
        }

    static Array* parseDataList(String* str)
        {
        Array* out = new Array();
        Array* parts = str.splitOnByte((u8)',');
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
            {
            String* t = XaText.tws((String*)parts.get(i));
            if (t.byteLength() > (u32)0)
                out.add((Object*)t);
            }
        return out;
        }

    XaLine* parseLine(String* rawLine, u32 lineNum)
        {
        XaLine* pl = new XaLine();
        pl.setSourceLine(lineNum);
        pl.setRawText(rawLine);
        String* line = stripComment(rawLine);
        String* trimmed = XaText.tws(line);
        if (trimmed.byteLength() == (u32)0)
            return pl;

        String* afterLabel = trimmed;
        u32 colon = trimmed.byteIndexOf(String.withCString(":"));
        if (colon != (u32)$FFFF_FFFF)
            {
            String* before = XaText.tws(trimmed.substringBytes((u32)0, colon));
            if (before.byteLength() > (u32)0 && isValidIdentifier(before))
                {
                if (before.hasPrefix(String.withCString(">")))
                    {
                    pl.setLabel(before.substringFromByte((u32)1));
                    pl.setLabelIsLocal(true);
                    }
                else if (before.hasPrefix(String.withCString(".")))
                    {
                    pl.setLabel(before); // the dot stays — scoped later
                    pl.setLabelIsLocal(true);
                    }
                else
                    {
                    pl.setLabel(before);
                    pl.setLabelIsLocal(false);
                    }
                afterLabel = XaText.tws(trimmed.substringFromByte(colon + (u32)1));
                }
            }
        if (afterLabel.byteLength() == (u32)0)
            {
            if (pl.label() != (String*)0)
                pl.setType((u32)LT_LABEL);
            return pl;
            }

        u32 eq = afterLabel.byteIndexOf(String.withCString("="));
        if (eq != (u32)$FFFF_FFFF && eq > (u32)0)
            {
            String* lhs = XaText.tws(afterLabel.substringBytes((u32)0, eq));
            String* rhs = XaText.tws(afterLabel.substringFromByte(eq + (u32)1));
            if (isValidIdentifier(lhs) && rhs.byteLength() > (u32)0 && !_cpu.isValidMnemonic(lhs))
                {
                pl.setType((u32)LT_ASSIGNMENT);
                pl.setAssign(lhs, rhs);
                return pl;
                }
            }

        if (parseDirective(pl, afterLabel))
            return pl;

        Array* parts = splitWhitespace(afterLabel);
        if (parts.count() == (u32)0)
            return pl;
        parseInstruction(pl, joinWith(parts, String.withCString(" ")));
        return pl;
        }

    bool parseDirective(XaLine* pl, String* afterLabel)
        {
        String* lc = afterLabel.lowercased();
        if (lc.hasPrefix(String.withCString(".org ")))
            {
            pl.setType((u32)LT_ORG);
            pl.setOperand(XaText.tws(afterLabel.substringFromByte((u32)4)));
            return true;
            }
        if (lc.hasPrefix(String.withCString(".bank ")))
            {
            pl.setType((u32)LT_BANK);
            pl.setOperand(XaText.tws(afterLabel.substringFromByte((u32)6)));
            pl.setByteSize((u32)0);
            return true;
            }
        if (lc.hasPrefix(String.withCString(".code_regions ")))
            {
            pl.setType((u32)LT_CODE_REGIONS);
            pl.setOperand(XaText.tws(afterLabel.substringFromByte((u32)14)));
            return true;
            }
        if (lc.hasPrefix(String.withCString(".shadow_ranges ")))
            {
            pl.setType((u32)LT_SHADOW_RANGES);
            pl.setOperand(XaText.tws(afterLabel.substringFromByte((u32)15)));
            return true;
            }
        if (lc.hasPrefix(String.withCString(".shadow_stage ")))
            {
            pl.setType((u32)LT_SHADOW_STAGE);
            pl.setOperand(XaText.tws(afterLabel.substringFromByte((u32)14)));
            return true;
            }
        if (lc.hasPrefix(String.withCString(".spill_point")))
            {
            pl.setType((u32)LT_SPILL_POINT);
            pl.setByteSize((u32)0);
            return true;
            }
        if (lc.hasPrefix(String.withCString(".cloaked_segment_end")))
            {
            pl.setType((u32)LT_CLOAKED_END);
            pl.setByteSize((u32)0);
            return true;
            }
        if (lc.hasPrefix(String.withCString(".cloaked_segment")))
            {
            pl.setType((u32)LT_CLOAKED_BEGIN);
            pl.setOperand(XaText.tws(afterLabel.substringFromByte((u32)16)));
            pl.setByteSize((u32)0);
            return true;
            }
        if (lc.hasPrefix(String.withCString(".byte ")))
            {
            pl.setType((u32)LT_BYTE);
            pl.setDataValues(parseDataList(afterLabel.substringFromByte((u32)5)));
            pl.setByteSize(pl.dataValues().count());
            return true;
            }
        if (lc.hasPrefix(String.withCString(".word ")))
            {
            pl.setType((u32)LT_WORD);
            pl.setDataValues(parseDataList(afterLabel.substringFromByte((u32)5)));
            pl.setByteSize(pl.dataValues().count() * (u32)2);
            return true;
            }
        if (lc.hasPrefix(String.withCString(".long ")))
            {
            pl.setType((u32)LT_LONG);
            pl.setDataValues(parseDataList(afterLabel.substringFromByte((u32)5)));
            pl.setByteSize(pl.dataValues().count() * (u32)4);
            return true;
            }
        if (lc.hasPrefix(String.withCString(".string ")))
            {
            pl.setType((u32)LT_STRING);
            String* v = XaText.tws(afterLabel.substringFromByte((u32)7));
            if (v.hasPrefix(String.withCString("\"")) && v.hasSuffix(String.withCString("\"")))
                v = v.substringBytes((u32)1, v.byteLength() - (u32)2);
            pl.setOperand(v);
            // Counted in characters, as the reference counts it, plus the NUL.
            pl.setByteSize(XaText.utf16Length(v) + (u32)1);
            return true;
            }
        if (lc.hasPrefix(String.withCString(".space ")))
            {
            pl.setType((u32)LT_SPACE);
            pl.setOperand(XaText.tws(afterLabel.substringFromByte((u32)6)));
            pl.setByteSize((u32)evaluate(pl.operand()));
            return true;
            }
        return false;
        }

    void parseInstruction(XaLine* pl, String* str)
        {
        Array* parts = splitWhitespace(str);
        if (parts.count() == (u32)0)
            return;
        String* mnemonic = ((String*)parts.get((u32)0)).uppercased();
        // Not an instruction: a macro invocation, already handled upstream.
        if (!_cpu.isValidMnemonic(mnemonic))
            return;

        pl.setType((u32)LT_INSTRUCTION);
        pl.setMnemonic(mnemonic);

        if (parts.count() == (u32)1)
            {
            // A bare shift or rotate means "operate on A"; everything else
            // with no operand is implied.
            if (mnemonic.equals(String.withCString("ASL")) || mnemonic.equals(String.withCString("LSR")) || mnemonic.equals(String.withCString("ROL")) || mnemonic.equals(String.withCString("ROR")))
                pl.setMode((u32)AM_ACCUMULATOR);
            else
                pl.setMode((u32)AM_IMPLIED);
            pl.setByteSize((u32)1);
            return;
            }
        Array* rest = new Array();
        for (u32 i = (u32)1; i < parts.count(); i = i + (u32)1)
            rest.add(parts.get(i));
        String* operand = XaText.tws(joinWith(rest, String.withCString(" ")));
        pl.setOperand(operand);
        pl.setMode(detectAddressingMode(operand, Xa6502.isBranchMnemonic(mnemonic)));
        pl.setByteSize(Xa6502.byteSizeForMode(pl.mode()));

        if (operand.uppercased().equals(String.withCString("A")))
            {
            pl.setMode((u32)AM_ACCUMULATOR);
            pl.setByteSize((u32)1);
            pl.setOperand((String*)0);
            }

        // Promote a zero-page form the mnemonic does not have to its absolute
        // one HERE, at parse time. Pass 2 has the same fallback, but it runs
        // after pass 1 has already stamped label addresses with the short
        // size — so every label past the instruction ends up a byte low and
        // the branch offsets miss. The classic case is `LDA $95,Y`: the
        // operand fits a byte so ZP,Y is detected, but only LDX and STX have
        // that mode.
        if (pl.mode() == (u32)AM_ZEROPAGE && _cpu.opcodeFor(pl.mnemonic(), (u32)AM_ZEROPAGE) < (i32)0 && _cpu.opcodeFor(pl.mnemonic(), (u32)AM_ABSOLUTE) >= (i32)0)
            {
            pl.setMode((u32)AM_ABSOLUTE);
            pl.setByteSize((u32)3);
            }
        else if (pl.mode() == (u32)AM_ZEROPAGEX && _cpu.opcodeFor(pl.mnemonic(), (u32)AM_ZEROPAGEX) < (i32)0 && _cpu.opcodeFor(pl.mnemonic(), (u32)AM_ABSOLUTEX) >= (i32)0)
            {
            pl.setMode((u32)AM_ABSOLUTEX);
            pl.setByteSize((u32)3);
            }
        else if (pl.mode() == (u32)AM_ZEROPAGEY && _cpu.opcodeFor(pl.mnemonic(), (u32)AM_ZEROPAGEY) < (i32)0 && _cpu.opcodeFor(pl.mnemonic(), (u32)AM_ABSOLUTEY) >= (i32)0)
            {
            pl.setMode((u32)AM_ABSOLUTEY);
            pl.setByteSize((u32)3);
            }
        }

    // The xt additions are checked BEFORE the generic `),Y` and `,X` forms,
    // which would otherwise capture them.
    u32 detectAddressingMode(String* operand, bool isBranch)
        {
        if (isBranch)
            return (u32)AM_RELATIVE;
        String* op = stripSpacesAroundCommas(XaText.tws(operand));
        String* up = op.uppercased();

        if (op.hasPrefix(String.withCString("(")) && up.hasSuffix(String.withCString(",SP),Y")))
            return (u32)AM_SPINDIRECTINDEXEDY;
        if (up.hasSuffix(String.withCString(",SP,X")))
            return (u32)AM_SPINDEXEDX;
        if (up.hasSuffix(String.withCString(",SP")))
            return (u32)AM_SPRELATIVE;
        if (up.hasPrefix(String.withCString("SP,")))
            return (u32)AM_STACKADJUST;

        if (op.hasPrefix(String.withCString("#")))
            return (u32)AM_IMMEDIATE;
        if (op.hasPrefix(String.withCString("(")) && up.hasSuffix(String.withCString("),Y")))
            return (u32)AM_INDIRECTINDEXEDY;
        if (op.hasPrefix(String.withCString("(")) && up.hasSuffix(String.withCString(",X)")))
            return (u32)AM_INDEXEDINDIRECTX;
        if (op.hasPrefix(String.withCString("(")) && op.hasSuffix(String.withCString(")")))
            return (u32)AM_INDIRECT;
        if (up.hasSuffix(String.withCString(",X")))
            {
            i64 v = tryEvaluate(op.substringBytes((u32)0, op.byteLength() - (u32)2));
            return (v >= (i64)0 && v <= (i64)$FF) ? (u32)AM_ZEROPAGEX : (u32)AM_ABSOLUTEX;
            }
        if (up.hasSuffix(String.withCString(",Y")))
            {
            i64 v = tryEvaluate(op.substringBytes((u32)0, op.byteLength() - (u32)2));
            return (v >= (i64)0 && v <= (i64)$FF) ? (u32)AM_ZEROPAGEY : (u32)AM_ABSOLUTEY;
            }
        i64 v = tryEvaluate(op);
        return (v >= (i64)0 && v <= (i64)$FF) ? (u32)AM_ZEROPAGE : (u32)AM_ABSOLUTE;
        }

    // Every space immediately before or after a comma goes: `$0602 , Y` is
    // `$0602,Y`.
    static String* stripSpacesAroundCommas(String* s)
        {
        u32 n = s.byteLength();
        String* o = new String();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)' ')
                {
                // A run of spaces touching a comma on either side vanishes.
                u32 j = i;
                while (j < n && s.byteAt(j) == (u8)' ')
                    j = j + (u32)1;
                bool nextComma = j < n && s.byteAt(j) == (u8)',';
                bool prevComma = i > (u32)0 && s.byteAt(i - (u32)1) == (u8)',';
                if (!nextComma && !prevComma)
                    {
                    for (u32 k = i; k < j; k = k + (u32)1)
                        o.appendByte((u8)' ');
                    }
                i = j - (u32)1;
                continue;
                }
            o.appendByte(c);
            }
        return o;
        }

    static Array* splitWhitespace(String* s)
        {
        Array* out = new Array();
        String* cur = new String();
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)' ' || c == (u8)'\t')
                {
                if (cur.byteLength() > (u32)0)
                    {
                    out.add((Object*)cur);
                    cur = new String();
                    }
                continue;
                }
            cur.appendByte(c);
            }
        if (cur.byteLength() > (u32)0)
            out.add((Object*)cur);
        return out;
        }

    static String* joinWith(Array* a, String* sep)
        {
        String* o = new String();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                o.append(sep);
            o.append((String*)a.get(i));
            }
        return o;
        }

    // ── Operand extraction ───────────────────────────────────────────────
    //
    // The signed-offset modes prefix a `0`: the expression evaluator only
    // splits on an operator at index > 0, so `+5` has to become `0+5` for the
    // leading sign to parse as a binary operator rather than a stray token.
    String* extractExpression(String* operand, u32 mode)
        {
        if (operand == (String*)0)
            return String.withCString("0");
        String* op = XaText.tws(operand);
        if (mode == (u32)AM_IMMEDIATE)
            return op.substringFromByte((u32)1);
        if (mode == (u32)AM_INDEXEDINDIRECTX)
            return XaText.tws(op.substringBytes((u32)1, op.byteLength() - (u32)4));
        if (mode == (u32)AM_INDIRECTINDEXEDY)
            {
            u32 paren = op.byteIndexOf(String.withCString(")"));
            return XaText.tws(op.substringBytes((u32)1, paren - (u32)1));
            }
        if (mode == (u32)AM_INDIRECT)
            return XaText.tws(op.substringBytes((u32)1, op.byteLength() - (u32)2));
        if (mode == (u32)AM_ZEROPAGEX || mode == (u32)AM_ABSOLUTEX || mode == (u32)AM_ZEROPAGEY || mode == (u32)AM_ABSOLUTEY)
            return XaText.tws(op.substringBytes((u32)0, op.byteLength() - (u32)2));
        if (mode == (u32)AM_SPRELATIVE || mode == (u32)AM_SPINDEXEDX)
            {
            u32 sp = lastIndexOfSP(op);
            String* inner = sp == (u32)$FFFF_FFFF ? op : op.substringBytes((u32)0, sp);
            return zeroPrefixed(XaText.tws(inner));
            }
        if (mode == (u32)AM_STACKADJUST)
            {
            String* after = XaText.tws(op.substringFromByte((u32)3));
            if (after.hasPrefix(String.withCString("#")))
                after = after.substringFromByte((u32)1);
            return zeroPrefixed(after);
            }
        if (mode == (u32)AM_SPINDIRECTINDEXEDY)
            {
            u32 sp = lastIndexOfSP(op);
            String* inner = (sp == (u32)$FFFF_FFFF || op.byteLength() < (u32)1)
                                ? op
                                : op.substringBytes((u32)1, sp - (u32)1);
            return zeroPrefixed(XaText.tws(inner));
            }
        return op;
        }

    static String* zeroPrefixed(String* s)
        {
        String* o = String.withCString("0");
        o.append(s);
        return o;
        }

    // The rightmost `,SP`, case-insensitively.
    static u32 lastIndexOfSP(String* op)
        {
        u32 found = (u32)$FFFF_FFFF;
        for (u32 i = (u32)0; i + (u32)2 < op.byteLength(); i = i + (u32)1)
            {
            if (op.byteAt(i) != (u8)',')
                continue;
            u8 a = op.byteAt(i + (u32)1);
            u8 b = op.byteAt(i + (u32)2);
            if ((a == (u8)'S' || a == (u8)'s') && (b == (u8)'P' || b == (u8)'p'))
                found = i;
            }
        return found;
        }

    static bool isIdentChar(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_';
        }
    static bool isIdentStart(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || c == (u8)'_';
        }

    // Scope a dot-prefixed local label reference to the enclosing global. A
    // dot starts a reference only when an identifier starts after it and none
    // ends before it — `fpAdd.fa_ret_a`, already scoped, stays alone — and the
    // directive names are never references.
    String* scopeLocalLabelsInOperand(String* operand)
        {
        if (_lastGlobalLabel == (String*)0 || operand == (String*)0)
            return operand;
        if (operand.byteIndexOf(String.withCString(".")) == (u32)$FFFF_FFFF)
            return operand;
        String* out = new String();
        u32 n = operand.byteLength();
        u32 i = (u32)0;
        while (i < n)
            {
            u8 c = operand.byteAt(i);
            bool prevIdent = i > (u32)0 && isIdentChar(operand.byteAt(i - (u32)1));
            if (c == (u8)'.' && !prevIdent && i + (u32)1 < n && isIdentStart(operand.byteAt(i + (u32)1)))
                {
                u32 j = i + (u32)1;
                while (j < n && isIdentChar(operand.byteAt(j)))
                    j = j + (u32)1;
                String* ref = operand.substringBytes(i, j - i);
                String* name = ref.substringFromByte((u32)1);
                bool directive = name.equals(String.withCString("byte")) || name.equals(String.withCString("word")) || name.equals(String.withCString("org")) || name.equals(String.withCString("dbyte")) || name.equals(String.withCString("end"));
                if (!directive)
                    out.append(_lastGlobalLabel);
                out.append(ref);
                i = j;
                continue;
                }
            out.appendByte(c);
            i = i + (u32)1;
            }
        return out;
        }

    // ── Pass 1 ───────────────────────────────────────────────────────────
    //
    // Sub-phase 1a parses and scope-resolves every line without touching the
    // PC, so 1b can walk a flat list and assign addresses.
    u32 _bankWindowSegSeen;
    u32 _curDirectiveBank;

    void pass1(Array* sourceLines)
        {
        _lines = new Array();
        _pc = (u32)0;
        _lastGlobalLabel = (String*)0;
        _codeRegions = (Array*)0;
        _currentRegionIndex = (u32)0;
        _pcInsideMainRegion = false;
        _inCloakedSegment = false;
        _finalRegionOverflowReported = false;
        _bankIds = new Map();
        _labelBank = new Map();
        _bankWindowSegSeen = (u32)0;
        _curDirectiveBank = (u32)0;

        for (u32 i = (u32)0; i < sourceLines.count(); i = i + (u32)1)
            {
            String* rawLine = (String*)sourceLines.get(i);
            String* line = stripComment(rawLine);
            Array* compounds = splitCompoundLine(line);
            bool lineIsLongbrInverse =
                rawLine.byteIndexOf(String.withCString("; longbr")) != (u32)$FFFF_FFFF;
            for (u32 k = (u32)0; k < compounds.count(); k = k + (u32)1)
                {
                XaLine* pl = parseLine((String*)compounds.get(k), i + (u32)1);
                if (lineIsLongbrInverse)
                    pl.setLongbrInverse(true);
                // A dotted local becomes `<lastGlobal>.<name>`. The long-branch
                // rewriter's own `_xlb_N` skip labels must NOT become the new
                // enclosing global, or every dotted label after one gets scoped
                // to the skip label instead of the routine.
                if (pl.label() != (String*)0)
                    {
                    if (pl.label().hasPrefix(String.withCString(".")) && _lastGlobalLabel != (String*)0)
                        {
                        String* scoped = new String();
                        scoped.append(_lastGlobalLabel);
                        scoped.append(pl.label());
                        pl.setLabel(scoped);
                        }
                    else if (!pl.labelIsLocal() && !pl.label().hasPrefix(String.withCString("_xlb_")))
                        {
                        _lastGlobalLabel = pl.label();
                        }
                    }
                if (pl.operand() != (String*)0)
                    pl.setOperand(scopeLocalLabelsInOperand(pl.operand()));
                _lines.add((Object*)pl);
                }
            }
        assignAddresses();
        reevaluateAssignments();
        dropResolvedWarnings();
        }

    void assignAddresses(void)
        {
        bool haveBankWindow = _bankWindowStart != (u32)0 || _bankWindowEnd != (u32)0;
        for (u32 idx = (u32)0; idx < _lines.count(); idx = idx + (u32)1)
            {
            XaLine* pl = (XaLine*)_lines.get(idx);
            checkFinalRegion(pl);
            idx = maybeAutoSpill(idx);
            pl = (XaLine*)_lines.get(idx);
            if (pl.label() != (String*)0)
                {
                if (!pl.labelIsLocal() && _symbols.get((Hashable*)pl.label()) != (Object*)0 && platformSymbols().get((Hashable*)pl.label()) == (Object*)0)
                    {
                    String* m = where(pl.sourceLine());
                    m.appendCString("duplicate label '");
                    m.append(pl.label());
                    m.appendCString("'");
                    err(m);
                    }
                _symbols.set((Hashable*)pl.label(), (Object*)Number.withI64((i64)_pc));
                // Tag a label defined inside a `.bank` region with that bank,
                // so an external JSR/JMP to it can be routed through the
                // trampoline rather than jumping into an unmapped page.
                if (_curDirectiveBank != (u32)0)
                    _labelBank.set((Hashable*)pl.label(),
                                   (Object*)Number.withU32(_curDirectiveBank));
                }
            u32 t = pl.type();
            if (t == (u32)LT_ORG)
                {
                _pc = (u32)evaluate(pl.operand()) & (u32)$FFFF;
                syncCurrentRegionToPC();
                // A plain `.org` into the bank window is a codegen user bank.
                // Count it, so a later `.bank` identifier is allocated a number
                // that cannot clash — but do not tag its labels, because the
                // code generator stages those cross-bank calls itself.
                if (haveBankWindow && _pc >= _bankWindowStart && _pc <= _bankWindowEnd)
                    _bankWindowSegSeen = _bankWindowSegSeen + (u32)1;
                _curDirectiveBank = (u32)0;
                continue;
                }
            if (t == (u32)LT_BANK)
                {
                String* id = pl.operand() == (String*)0 ? String.withCString("") : pl.operand();
                Object* assigned = _bankIds.get((Hashable*)id);
                if (assigned == (Object*)0)
                    {
                    _bankWindowSegSeen = _bankWindowSegSeen + (u32)1;
                    assigned = (Object*)Number.withU32(_bankWindowSegSeen);
                    _bankIds.set((Hashable*)id, assigned);
                    }
                // Publish `__bank_<id>` so the harness's unbanked thunks can
                // stage the bank number without knowing the allocation.
                String* symName = String.withCString("__bank_");
                symName.append(id);
                _symbols.set((Hashable*)symName, (Object*)Number.withI64((i64)((Number*)assigned).asU32()));
                _curDirectiveBank = ((Number*)assigned).asU32();
                _pc = _bankWindowStart & (u32)$FFFF;
                syncCurrentRegionToPC();
                continue;
                }
            if (t == (u32)LT_CLOAKED_BEGIN)
                {
                // `<addr> [<bank>]`: only the address matters for sizing.
                String* addrExpr = firstToken(pl.operand());
                _pc = (u32)evaluate(addrExpr == (String*)0 ? String.withCString("") : addrExpr) & (u32)$FFFF;
                syncCurrentRegionToPC();
                _inCloakedSegment = true;
                continue;
                }
            if (t == (u32)LT_CLOAKED_END)
                {
                _inCloakedSegment = false;
                continue;
                }
            if (t == (u32)LT_CODE_REGIONS)
                {
                _codeRegions = parseRegionList(pl.operand(), pl.sourceLine());
                syncCurrentRegionToPC();
                continue;
                }
            if (t == (u32)LT_SHADOW_RANGES)
                {
                _shadowRanges = parseRegionList(pl.operand(), pl.sourceLine());
                continue;
                }
            if (t == (u32)LT_SHADOW_STAGE)
                {
                i64 v = evaluate(pl.operand());
                if (v < (i64)0 || v > (i64)$FFFF)
                    {
                    String* m = where(pl.sourceLine());
                    m.appendCString("invalid .shadow_stage address '");
                    m.append(pl.operand());
                    m.appendCString("'");
                    err(m);
                    }
                else
                    _shadowStageBase = (u32)v;
                continue;
                }
            if (t == (u32)LT_SPILL_POINT)
                {
                handleSpillPoint(idx);
                continue;
                }
            if (t == (u32)LT_ASSIGNMENT)
                {
                _symbols.set((Hashable*)pl.assignName(),
                             (Object*)Number.withI64(evaluate(pl.assignValue())));
                // An alias for a banked label inherits its bank, so a call
                // through the alias still routes through the trampoline.
                String* rhs = XaText.tws(pl.assignValue());
                Object* rhsBank = _labelBank.get((Hashable*)rhs);
                if (rhsBank != (Object*)0)
                    _labelBank.set((Hashable*)pl.assignName(), rhsBank);
                continue;
                }
            if (t == (u32)LT_INSTRUCTION || t == (u32)LT_BYTE || t == (u32)LT_WORD || t == (u32)LT_LONG || t == (u32)LT_STRING || t == (u32)LT_SPACE)
                {
                pl.setAddress(_pc);
                _pc = (_pc + pl.byteSize()) & (u32)$FFFF;
                }
            }
        }

    // The first whitespace-separated token, or null.
    static String* firstToken(String* s)
        {
        if (s == (String*)0)
            return (String*)0;
        Array* parts = splitWhitespace(s);
        return parts.count() == (u32)0 ? (String*)0 : (String*)parts.get((u32)0);
        }

    // An equate that names a label further down resolved to 0 on the first
    // sweep. Now every label is known, sweep the equates again until nothing
    // changes (four times at most, so two that name each other terminate).
    void reevaluateAssignments(void)
        {
        for (u32 epoch = (u32)0; epoch < (u32)4; epoch = epoch + (u32)1)
            {
            bool changed = false;
            for (u32 i = (u32)0; i < _lines.count(); i = i + (u32)1)
                {
                XaLine* pl = (XaLine*)_lines.get(i);
                if (pl.type() != (u32)LT_ASSIGNMENT)
                    continue;
                i64 v = evaluate(pl.assignValue());
                Object* cur = _symbols.get((Hashable*)pl.assignName());
                if (cur == (Object*)0 || ((Number*)cur).asI64() != v)
                    {
                    _symbols.set((Hashable*)pl.assignName(), (Object*)Number.withI64(v));
                    changed = true;
                    }
                }
            if (!changed)
                break;
            }
        }

    // "undefined symbol 'X'" from before X was defined is not a diagnostic.
    void dropResolvedWarnings(void)
        {
        if (_warnings.count() == (u32)0)
            return;
        Array* kept = new Array();
        String* marker = String.withCString("undefined symbol '");
        for (u32 i = (u32)0; i < _warnings.count(); i = i + (u32)1)
            {
            String* w = (String*)_warnings.get(i);
            bool drop = false;
            u32 r = w.byteIndexOf(marker);
            if (r != (u32)$FFFF_FFFF)
                {
                u32 start = r + marker.byteLength();
                u32 end = w.byteIndexOf(String.withCString("'"), start);
                if (end != (u32)$FFFF_FFFF)
                    {
                    String* s = w.substringBytes(start, end - start);
                    if (_symbols.get((Hashable*)s) != (Object*)0)
                        drop = true;
                    }
                }
            if (!drop)
                kept.add((Object*)w);
            }
        _warnings = kept;
        }

    static bool emitsBytes(XaLine* pl)
        {
        u32 t = pl.type();
        return t == (u32)LT_INSTRUCTION || t == (u32)LT_BYTE || t == (u32)LT_WORD || t == (u32)LT_LONG || t == (u32)LT_STRING || t == (u32)LT_SPACE;
        }

    u32 regionLo(u32 i)
        {
        return ((Number*)_codeRegions.get(i * (u32)2)).asU32();
        }
    u32 regionHi(u32 i)
        {
        return ((Number*)_codeRegions.get(i * (u32)2 + (u32)1)).asU32();
        }

    // With no region after this one, running past its end is fatal — once.
    void checkFinalRegion(XaLine* pl)
        {
        if (_codeRegions == (Array*)0 || _inCloakedSegment || !_pcInsideMainRegion)
            return;
        u32 nRegions = _codeRegions.count() / (u32)2;
        if (_currentRegionIndex + (u32)1 < nRegions)
            return;
        if (!emitsBytes(pl) || pl.byteSize() == (u32)0)
            return;
        u32 finalEnd = regionHi(_currentRegionIndex);
        if (_pc + pl.byteSize() > finalEnd + (u32)1 && !_finalRegionOverflowReported)
            {
            String* m = where(pl.sourceLine());
            m.appendCString("program exceeds the declared .code_regions (last region ends at $");
            m.append(XaText.hex4(finalEnd));
            m.appendCString(", tried to emit past it at PC $");
            m.append(XaText.hex4(_pc));
            m.appendCString("). Reduce code size or add a larger region to the layout.");
            err(m);
            _finalRegionOverflowReported = true;
            }
        }

    // Code lives in declared REGIONS with hardware in the gaps. An instruction
    // that would cross a boundary is bridged into the next region — with a JMP
    // when something falls through into it, or just a `.org` when the previous
    // instruction was an unconditional transfer and nothing does.
    //
    // The runway is ten bytes rather than three: it leaves room for both a JMP
    // bridge AND a short-branch-plus-JMP pattern, so the long-branch rewriter's
    // inverse branch, its JMP and its skip label stay on the same side of the
    // gap.
    u32 maybeAutoSpill(u32 idx)
        {
        if (_codeRegions == (Array*)0 || _inCloakedSegment || !_pcInsideMainRegion)
            return idx;
        XaLine* pl = (XaLine*)_lines.get(idx);
        if (!emitsBytes(pl) || pl.byteSize() == (u32)0)
            return idx;
        u32 nRegions = _codeRegions.count() / (u32)2;
        if (_currentRegionIndex + (u32)1 >= nRegions)
            return idx;
        u32 regionEnd = regionHi(_currentRegionIndex);
        u32 tail = _pc + pl.byteSize();
        u32 limit = regionEnd + (u32)1;
        if (limit < (u32)10 || tail <= limit - (u32)10)
            return idx;

        bool lineIsSpace = pl.type() == (u32)LT_SPACE;
        bool prevIsTransfer = false;
        bool prevIsLongbrInverse = false;
        if (idx > (u32)0)
            {
            XaLine* prev = (XaLine*)_lines.get(idx - (u32)1);
            if (prev.type() == (u32)LT_INSTRUCTION && (prev.mnemonic().equals(String.withCString("JMP")) || prev.mnemonic().equals(String.withCString("RTS")) || prev.mnemonic().equals(String.withCString("RTI"))))
                prevIsTransfer = true;
            if (prev.isLongbrInverse())
                prevIsLongbrInverse = true;
            }
        u32 nextStart = regionLo(_currentRegionIndex + (u32)1);
        String* target = String.withCString("$");
        target.append(XaText.hex4(nextStart));

        if (prevIsTransfer || lineIsSpace)
            {
            // Nothing falls through — a `.space` is never executed and a
            // transfer already left — so the bridge is just a `.org`.
            // Return idx pointing AT the inserted line, so the caller
            // processes it — the whole point is that the `.org` moves the PC.
            _lines.insert(idx, (Object*)makeOrg(target, pl.sourceLine()));
            return idx;
            }
        if (!prevIsLongbrInverse)
            {
            if (_pc + (u32)3 > regionEnd + (u32)1)
                {
                String* m = where(pl.sourceLine());
                m.appendCString("region $");
                m.append(XaText.hex4(regionLo(_currentRegionIndex)));
                m.appendCString("-$");
                m.append(XaText.hex4(regionEnd));
                m.appendCString(" too full for auto-spill JMP bridge at PC $");
                m.append(XaText.hex4(_pc));
                err(m);
                return idx;
                }
            XaLine* jmp = new XaLine();
            jmp.setType((u32)LT_INSTRUCTION);
            jmp.setMnemonic(String.withCString("JMP"));
            jmp.setOperand(target);
            jmp.setMode((u32)AM_ABSOLUTE);
            jmp.setByteSize((u32)3);
            String* raw = String.withCString("    JMP ");
            raw.append(target);
            raw.appendCString(" ; auto-spill");
            jmp.setRawText(raw);
            jmp.setSourceLine(pl.sourceLine());
            _lines.insert(idx, (Object*)jmp);
            _lines.insert(idx + (u32)1, (Object*)makeOrg(target, pl.sourceLine()));
            return idx;
            }
        return idx;
        }

    static XaLine* makeOrg(String* target, u32 srcLine)
        {
        XaLine* org = new XaLine();
        org.setType((u32)LT_ORG);
        org.setOperand(target);
        String* raw = String.withCString("    .org ");
        raw.append(target);
        raw.appendCString(" ; auto-spill");
        org.setRawText(raw);
        org.setSourceLine(srcLine);
        return org;
        }

    // A `.spill_point` sizes the chunk up to the next spill point or `.org`.
    // If it would not fit the rest of the current region and there is a next
    // one, the spill point becomes a `.org` there.
    void handleSpillPoint(u32 idx)
        {
        if (_codeRegions == (Array*)0)
            return;
        u32 nRegions = _codeRegions.count() / (u32)2;
        if (_currentRegionIndex + (u32)1 >= nRegions)
            return;
        u32 regionEnd = regionHi(_currentRegionIndex);
        u32 chunk = (u32)0;
        for (u32 j = idx + (u32)1; j < _lines.count(); j = j + (u32)1)
            {
            XaLine* peek = (XaLine*)_lines.get(j);
            if (peek.type() == (u32)LT_SPILL_POINT || peek.type() == (u32)LT_ORG)
                break;
            chunk = chunk + peek.byteSize();
            if (_pc + chunk > regionEnd + (u32)1)
                break;
            }
        if (_pc + chunk <= regionEnd + (u32)1)
            return;
        u32 next = _currentRegionIndex + (u32)1;
        u32 nextStart = regionLo(next);
        XaLine* pl = (XaLine*)_lines.get(idx);
        pl.setType((u32)LT_ORG);
        String* target = String.withCString("$");
        target.append(XaText.hex4(nextStart));
        pl.setOperand(target);
        _pc = nextStart;
        _currentRegionIndex = next;
        }

    void syncCurrentRegionToPC(void)
        {
        _pcInsideMainRegion = false;
        if (_codeRegions == (Array*)0)
            return;
        for (u32 i = (u32)0; i + (u32)1 < _codeRegions.count(); i = i + (u32)2)
            {
            u32 lo = ((Number*)_codeRegions.get(i)).asU32();
            u32 hi = ((Number*)_codeRegions.get(i + (u32)1)).asU32();
            if (_pc >= lo && _pc <= hi)
                {
                _currentRegionIndex = i / (u32)2;
                _pcInsideMainRegion = true;
                return;
                }
            }
        }

    // `$2400-$3FFF, $D800-$FFF9` — a flat list of lo/hi pairs. A malformed
    // entry is an error and yields no list at all.
    Array* parseRegionList(String* operand, u32 line)
        {
        if (operand == (String*)0 || operand.byteLength() == (u32)0)
            return (Array*)0;
        Array* out = new Array();
        Array* parts = operand.splitOnByte((u8)',');
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
            {
            String* p = XaText.tws((String*)parts.get(i));
            if (p.byteLength() == (u32)0)
                continue;
            u32 dash = p.indexOfByte((u8)'-');
            if (dash == (u32)$FFFF_FFFF)
                {
                String* m = where(line);
                m.appendCString("malformed .code_regions entry '");
                m.append(p);
                m.appendCString("' (expected $START-$END)");
                err(m);
                return (Array*)0;
                }
            i64 lo = evaluate(XaText.tws(p.substringBytes((u32)0, dash)));
            i64 hi = evaluate(XaText.tws(p.substringFromByte(dash + (u32)1)));
            if (lo < (i64)0 || hi < (i64)0 || hi < lo)
                {
                String* m = where(line);
                m.appendCString("invalid .code_regions range '");
                m.append(p);
                m.appendCString("'");
                err(m);
                return (Array*)0;
                }
            out.add((Object*)Number.withU32((u32)lo & (u32)$FFFF));
            out.add((Object*)Number.withU32((u32)hi & (u32)$FFFF));
            }
        return out;
        }

    // ── Pass 2 ───────────────────────────────────────────────────────────
    //
    // Resolve every expression and emit bytes into origin-tagged segments.
    // A small forward `.org` pads with zeros and keeps the current segment
    // going — the banked target packs several functions onto one page and each
    // would otherwise become its own load segment, so calls would land on the
    // wrong page. A large jump starts a NEW segment, because padding across a
    // zone change would collapse two regions into one load.
    XaSegment* ensureSegment(XaSegment* cur)
        {
        if (cur != (XaSegment*)0)
            return cur;
        XaSegment* s = XaSegment.at(_pc);
        _segments.add((Object*)s);
        return s;
        }

    void pass2(void)
        {
        _segments = new Array();
        XaSegment* cur = (XaSegment*)0;
        _pc = (u32)0;
        for (u32 i = (u32)0; i < _lines.count(); i = i + (u32)1)
            {
            XaLine* pl = (XaLine*)_lines.get(i);
            u32 t = pl.type();
            if (t == (u32)LT_ORG)
                {
                u32 newPc = (u32)evaluate(pl.operand()) & (u32)$FFFF;
                bool forward = cur != (XaSegment*)0 && newPc >= _pc;
                bool sameSlot = cur != (XaSegment*)0 && newPc == cur.origin() && cur.data().count() == (u32)0;
                // A spill-rewritten `.org` moves from one declared region into
                // the next. The addresses can be a handful of bytes apart, so
                // the padding rule below would otherwise zero-fill across the
                // gap and keep both regions in ONE load block — which the
                // hardware will not honour past the first region's end.
                bool crossesRegion = false;
                if (forward && _codeRegions != (Array*)0 && _codeRegions.count() > (u32)2)
                    {
                    i32 a = regionIndexOf(_pc);
                    i32 b = regionIndexOf(newPc);
                    crossesRegion = a >= (i32)0 && b >= (i32)0 && b > a;
                    }
                if (forward && newPc - _pc < (u32)$100 && !sameSlot && !crossesRegion)
                    {
                    while (_pc < newPc)
                        {
                        cur.data().add((Object*)Number.withU32((u32)0));
                        _pc = _pc + (u32)1;
                        }
                    continue;
                    }
                _pc = newPc;
                cur = XaSegment.at(newPc);
                _segments.add((Object*)cur);
                continue;
                }
            if (t == (u32)LT_CLOAKED_BEGIN)
                {
                // `<addr> [<bank>]`, the bank the literal `none` (banking off)
                // or an index. A missing bank means none.
                Array* parts = pl.operand() == (String*)0 ? new Array() : splitWhitespace(pl.operand());
                String* addrExpr = parts.count() > (u32)0 ? (String*)parts.get((u32)0) : String.withCString("");
                i32 bankIndex = (i32)-1;
                if (parts.count() > (u32)1)
                    {
                    String* bankTok = (String*)parts.get((u32)1);
                    if (!bankTok.lowercased().equals(String.withCString("none")))
                        bankIndex = (i32)evaluate(bankTok);
                    }
                _pc = (u32)evaluate(addrExpr) & (u32)$FFFF;
                cur = XaSegment.at(_pc);
                cur.setCloaked(true);
                cur.setCloakedBankIndex(bankIndex);
                _segments.add((Object*)cur);
                continue;
                }
            if (t == (u32)LT_CLOAKED_END)
                {
                cur = (XaSegment*)0;
                continue;
                }
            if (t == (u32)LT_BANK)
                {
                // Open a named banked region: a fresh segment at the bank
                // window, carrying the identifier's pre-allocated physical bank
                // number so the writer's preload stub matches what the
                // cross-bank staging expects.
                _pc = _bankWindowStart & (u32)$FFFF;
                cur = XaSegment.at(_pc);
                String* id = pl.operand() == (String*)0 ? String.withCString("") : pl.operand();
                Object* bn = _bankIds.get((Hashable*)id);
                cur.setBankNumber(bn == (Object*)0 ? (i32)-1 : (i32)((Number*)bn).asU32());
                _segments.add((Object*)cur);
                continue;
                }
            if (t == (u32)LT_INSTRUCTION)
                {
                cur = ensureSegment(cur);
                emitInstruction(pl, cur);
                _pc = (_pc + pl.byteSize()) & (u32)$FFFF;
                continue;
                }
            if (t == (u32)LT_BYTE)
                {
                cur = ensureSegment(cur);
                Array* vs = pl.dataValues();
                for (u32 k = (u32)0; k < vs.count(); k = k + (u32)1)
                    cur.data().add((Object*)Number.withU32((u32)evaluate((String*)vs.get(k)) & (u32)$FF));
                _pc = (_pc + pl.byteSize()) & (u32)$FFFF;
                continue;
                }
            if (t == (u32)LT_WORD)
                {
                cur = ensureSegment(cur);
                Array* vs = pl.dataValues();
                for (u32 k = (u32)0; k < vs.count(); k = k + (u32)1)
                    {
                    u32 v = (u32)evaluate((String*)vs.get(k));
                    cur.data().add((Object*)Number.withU32(v & (u32)$FF));
                    cur.data().add((Object*)Number.withU32((v >> (u32)8) & (u32)$FF));
                    }
                _pc = (_pc + pl.byteSize()) & (u32)$FFFF;
                continue;
                }
            if (t == (u32)LT_LONG)
                {
                cur = ensureSegment(cur);
                Array* vs = pl.dataValues();
                for (u32 k = (u32)0; k < vs.count(); k = k + (u32)1)
                    {
                    u32 v = (u32)evaluate((String*)vs.get(k));
                    for (u32 b = (u32)0; b < (u32)4; b = b + (u32)1)
                        cur.data().add((Object*)Number.withU32((v >> ((u32)8 * b)) & (u32)$FF));
                    }
                _pc = (_pc + pl.byteSize()) & (u32)$FFFF;
                continue;
                }
            if (t == (u32)LT_STRING)
                {
                cur = ensureSegment(cur);
                String* v = pl.operand();
                for (u32 k = (u32)0; k < v.byteLength(); k = k + (u32)1)
                    cur.data().add((Object*)Number.withU32((u32)v.byteAt(k)));
                cur.data().add((Object*)Number.withU32((u32)0));
                _pc = (_pc + pl.byteSize()) & (u32)$FFFF;
                continue;
                }
            if (t == (u32)LT_SPACE)
                {
                cur = ensureSegment(cur);
                for (u32 k = (u32)0; k < pl.byteSize(); k = k + (u32)1)
                    cur.data().add((Object*)Number.withU32((u32)0));
                _pc = (_pc + pl.byteSize()) & (u32)$FFFF;
                continue;
                }
            }
        }

    i32 regionIndexOf(u32 addr)
        {
        if (_codeRegions == (Array*)0)
            return (i32)-1;
        i32 found = (i32)-1;
        for (u32 i = (u32)0; i + (u32)1 < _codeRegions.count(); i = i + (u32)2)
            {
            u32 lo = ((Number*)_codeRegions.get(i)).asU32();
            u32 hi = ((Number*)_codeRegions.get(i + (u32)1)).asU32();
            if (addr >= lo && addr <= hi)
                found = (i32)(i / (u32)2);
            }
        return found;
        }

    // `line N: ` — pass 2's prefix.
    static String* lineRef(XaLine* pl)
        {
        String* m = String.withCString("line ");
        m.append(String.withU32(pl.sourceLine()));
        m.appendCString(": ");
        return m;
        }

    static String* orNull(String* s)
        {
        return s == (String*)0 ? String.withCString("(null)") : s;
        }

    static bool hasIdentLetter(String* s)
        {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if ((c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || c == (u8)'_' || c >= (u8)$80)
                return true;
            }
        return false;
        }

    void emitInstruction(XaLine* pl, XaSegment* seg)
        {
        i32 opcode = _cpu.opcodeFor(pl.mnemonic(), pl.mode());
        // The same zero-page-to-absolute promotion the parser does, kept here
        // as a backstop for a mode the parser could not resolve.
        if (opcode < (i32)0 && pl.mode() == (u32)AM_ZEROPAGE)
            {
            pl.setMode((u32)AM_ABSOLUTE);
            pl.setByteSize((u32)3);
            opcode = _cpu.opcodeFor(pl.mnemonic(), pl.mode());
            }
        if (opcode < (i32)0 && pl.mode() == (u32)AM_ZEROPAGEX)
            {
            pl.setMode((u32)AM_ABSOLUTEX);
            pl.setByteSize((u32)3);
            opcode = _cpu.opcodeFor(pl.mnemonic(), pl.mode());
            }
        if (opcode < (i32)0 && pl.mode() == (u32)AM_ZEROPAGEY)
            {
            pl.setMode((u32)AM_ABSOLUTEY);
            pl.setByteSize((u32)3);
            opcode = _cpu.opcodeFor(pl.mnemonic(), pl.mode());
            }
        if (opcode < (i32)0)
            {
            String* m = lineRef(pl);
            m.appendCString("invalid addressing mode for ");
            m.append(pl.mnemonic());
            err(m);
            return;
            }
        seg.data().add((Object*)Number.withU32((u32)opcode));
        if (pl.byteSize() == (u32)1)
            return;

        String* exprStr = extractExpression(pl.operand(), pl.mode());
        i64 value = evaluate(exprStr);

        // A symbolic memory operand that resolves to $0000 is almost always a
        // reference to a symbol nobody defined. Say so.
        if (value == (i64)0)
            {
            u32 md = pl.mode();
            bool mem = md == (u32)AM_ZEROPAGE || md == (u32)AM_ZEROPAGEX || md == (u32)AM_ZEROPAGEY || md == (u32)AM_ABSOLUTE || md == (u32)AM_ABSOLUTEX || md == (u32)AM_ABSOLUTEY || md == (u32)AM_INDIRECT;
            if (mem && hasIdentLetter(exprStr))
                {
                String* m = lineRef(pl);
                m.append(pl.mnemonic());
                m.appendCString(" ");
                m.append(exprStr);
                m.appendCString(" resolves to $0000 — probable undefined symbol (compiler internal error?)");
                warn(m);
                }
            }

        if (pl.mode() == (u32)AM_RELATIVE)
            {
            // The 6502's PC addition wraps at 16 bits, so the offset is masked
            // and sign-extended — a branch at $FFFE to $0003 is +3, not
            // -65533, and must not be flagged out of range.
            i64 offset = value - (i64)(_pc + (u32)2);
            i64 wrapped = offset & (i64)$FFFF;
            if (wrapped >= (i64)$8000)
                wrapped = wrapped - (i64)$10000;
            if (wrapped < (i64)-128 || wrapped > (i64)127)
                {
                String* m = lineRef(pl);
                m.appendCString("branch out of range (");
                m.append(XaText.dec(offset));
                m.appendCString(") — ");
                m.append(pl.mnemonic());
                m.appendCString(" ");
                m.append(orNull(pl.operand()));
                m.appendCString(" at $");
                m.append(XaText.hex4(_pc));
                m.appendCString(" → $");
                m.append(XaText.hex((u64)value, (u32)4));
                err(m);
                }
            seg.data().add((Object*)Number.withU32((u32)offset & (u32)$FF));
            return;
            }
        if (pl.mode() == (u32)AM_SPRELATIVE || pl.mode() == (u32)AM_STACKADJUST || pl.mode() == (u32)AM_SPINDIRECTINDEXEDY || pl.mode() == (u32)AM_SPINDEXEDX)
            {
            // A signed 8-bit immediate. Out of range is a hard error: silent
            // truncation would mis-target every stack access after it.
            if (value < (i64)-128 || value > (i64)127)
                {
                String* m = lineRef(pl);
                m.append(pl.mnemonic());
                m.appendCString(" ");
                m.append(orNull(pl.operand()));
                m.appendCString(" — signed-8-bit ");
                m.appendCString(pl.mode() == (u32)AM_SPRELATIVE ? "offset" : "stack adjustment");
                m.appendCString(" out of range (");
                m.append(XaText.dec(value));
                m.appendCString("); xt SP-relative addressing only reaches ±128 bytes");
                err(m);
                }
            seg.data().add((Object*)Number.withU32((u32)value & (u32)$FF));
            return;
            }
        if (pl.byteSize() == (u32)2 && pl.mode() == (u32)AM_IMMEDIATE && (pl.mnemonic().equals(String.withCString("PSH")) || pl.mnemonic().equals(String.withCString("PLL"))))
            {
            // PSH/PLL take an UNSIGNED byte; truncating would mis-size the
            // prologue's frame allocation.
            if (value < (i64)0 || value > (i64)255)
                {
                String* m = lineRef(pl);
                m.append(pl.mnemonic());
                m.appendCString(" #");
                m.append(XaText.dec(value));
                m.appendCString(" — immediate out of range (0..255); larger frames must chain PSH/PLL pairs (see STACK-ABI.md §6.1)");
                err(m);
                }
            seg.data().add((Object*)Number.withU32((u32)value & (u32)$FF));
            return;
            }
        if (pl.byteSize() == (u32)2)
            {
            // An indirect mode goes through a zero-page pointer; a wider
            // operand is silently truncated to its low byte by the hardware.
            if ((pl.mode() == (u32)AM_INDIRECTINDEXEDY || pl.mode() == (u32)AM_INDEXEDINDIRECTX) && (value < (i64)0 || value > (i64)$FF))
                {
                String* m = lineRef(pl);
                m.append(pl.mnemonic());
                m.appendCString(" ");
                m.append(orNull(pl.operand()));
                m.appendCString(" — indirect-indexed addressing requires a zero-page operand (got $");
                m.append(XaText.hex((u64)value, (u32)4));
                m.appendCString("). The symbol resolves to main memory (data-section spill?); the runtime read will go through ZP $");
                m.append(XaText.hex((u64)(value & (i64)$FF), (u32)2));
                m.appendCString(" which holds unrelated bytes. Likely a codegen-side ZP-pressure issue; if this code path executes the program will misbehave.");
                warn(m);
                }
            seg.data().add((Object*)Number.withU32((u32)value & (u32)$FF));
            return;
            }
        if (pl.byteSize() == (u32)3)
            {
            seg.data().add((Object*)Number.withU32((u32)value & (u32)$FF));
            seg.data().add((Object*)Number.withU32(((u32)value >> (u32)8) & (u32)$FF));
            }
        }

    // ── The long-branch rewriter ─────────────────────────────────────────
    //
    // A conditional branch that cannot reach its target becomes its INVERSE
    // over a JMP: `BEQ far` turns into `BNE skip / JMP far / skip:`. That is
    // three bytes longer, which moves every label after it — so the caller
    // re-runs pass 1 and this runs again, until nothing changes.
    //
    // BRA is unconditional, so an out-of-range one becomes a plain JMP with no
    // inverse-branch dance at all.
    u32 _longBranchCounter;

    u32 rewriteLongBranches(Array* sourceLines)
        {
        Array* pcMap = new Array();
        u32 pc = (u32)0;
        for (u32 i = (u32)0; i < _lines.count(); i = i + (u32)1)
            {
            XaLine* pl = (XaLine*)_lines.get(i);
            pcMap.add((Object*)Number.withU32(pc));
            if (pl.type() == (u32)LT_ORG)
                pc = (u32)evaluate(pl.operand()) & (u32)$FFFF;
            // A `.bank` region loads at the bank window, so the PC has to jump
            // there — otherwise every branch inside the banked runtime is
            // measured against the main region's cursor, comes out tens of
            // kilobytes away, and gets rewritten as an inverse-plus-JMP that
            // was never needed.
            else if (pl.type() == (u32)LT_BANK)
                pc = _bankWindowStart & (u32)$FFFF;
            else
                pc = (pc + pl.byteSize()) & (u32)$FFFF;
            }

        // One replacement per SOURCE line, applied back to front so the
        // earlier indices stay valid.
        Array* repIdx = new Array();
        Array* repText = new Array(); // Array@ of String@ per entry
        for (u32 i = (u32)0; i < _lines.count(); i = i + (u32)1)
            {
            XaLine* pl = (XaLine*)_lines.get(i);
            if (pl.type() != (u32)LT_INSTRUCTION)
                continue;
            if (!Xa6502.isBranchMnemonic(pl.mnemonic()))
                continue;
            String* targetExpr = pl.operand();
            if (targetExpr == (String*)0)
                continue;
            i64 target = evaluate(targetExpr);
            u32 branchPC = ((Number*)pcMap.get(i)).asU32();
            i64 offset = target - (i64)(branchPC + (u32)2);
            i64 wrapped = offset & (i64)$FFFF;
            if (wrapped >= (i64)$8000)
                wrapped = wrapped - (i64)$10000;
            if (wrapped >= (i64)-128 && wrapped <= (i64)127)
                continue;

            u32 srcLine = pl.sourceLine() - (u32)1;
            if (srcLine >= sourceLines.count())
                continue;
            if (containsIndex(repIdx, srcLine))
                continue;

            Array* lines = new Array();
            if (pl.mnemonic().equals(String.withCString("BRA")))
                {
                String* j = String.withCString("    JMP ");
                j.append(targetExpr);
                lines.add((Object*)j);
                }
            else
                {
                String* inverse = inverseBranch(pl.mnemonic());
                if (inverse == (String*)0)
                    continue;
                String* skip = String.withCString("_xlb_");
                skip.append(String.withU32(_longBranchCounter));
                _longBranchCounter = _longBranchCounter + (u32)1;
                String* a = String.withCString("    ");
                a.append(inverse);
                a.appendCString(" ");
                a.append(skip);
                a.appendCString(" ; longbr");
                String* b = String.withCString("    JMP ");
                b.append(targetExpr);
                String* c = new String();
                c.append(skip);
                c.appendCString(":");
                lines.add((Object*)a);
                lines.add((Object*)b);
                lines.add((Object*)c);
                }
            repIdx.add((Object*)Number.withU32(srcLine));
            repText.add((Object*)lines);
            }
        if (repIdx.count() == (u32)0)
            return (u32)0;

        // Back to front, so an insertion never shifts an index still to come.
        sortByIndexDescending(repIdx, repText);
        for (u32 r = (u32)0; r < repIdx.count(); r = r + (u32)1)
            {
            u32 at = ((Number*)repIdx.get(r)).asU32();
            Array* lines = (Array*)repText.get(r);
            sourceLines.set(at, lines.get((u32)0));
            for (u32 j = (u32)1; j < lines.count(); j = j + (u32)1)
                sourceLines.insert(at + j, lines.get(j));
            }
        return repIdx.count();
        }

    static bool containsIndex(Array* a, u32 v)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((Number*)a.get(i)).asU32() == v)
                return true;
        return false;
        }

    static void sortByIndexDescending(Array* idx, Array* txt)
        {
        for (u32 i = (u32)1; i < idx.count(); i = i + (u32)1)
            {
            Object* vi = idx.get(i);
            Object* vt = txt.get(i);
            u32 j = i;
            while (j > (u32)0 && ((Number*)idx.get(j - (u32)1)).asU32() < ((Number*)vi).asU32())
                {
                idx.set(j, idx.get(j - (u32)1));
                txt.set(j, txt.get(j - (u32)1));
                j = j - (u32)1;
                }
            idx.set(j, vi);
            txt.set(j, vt);
            }
        }

    static String* inverseBranch(String* m)
        {
        if (m.equals(String.withCString("BCC")))
            return String.withCString("BCS");
        if (m.equals(String.withCString("BCS")))
            return String.withCString("BCC");
        if (m.equals(String.withCString("BEQ")))
            return String.withCString("BNE");
        if (m.equals(String.withCString("BNE")))
            return String.withCString("BEQ");
        if (m.equals(String.withCString("BMI")))
            return String.withCString("BPL");
        if (m.equals(String.withCString("BPL")))
            return String.withCString("BMI");
        if (m.equals(String.withCString("BVC")))
            return String.withCString("BVS");
        if (m.equals(String.withCString("BVS")))
            return String.withCString("BVC");
        return (String*)0;
        }

    // ── Cross-bank call rewriting ────────────────────────────────────────
    //
    // A `JSR`/`JMP` to a bare label defined inside a `.bank` region, made from
    // a DIFFERENT bank, is retargeted onto that entry's unbanked thunk:
    // `JSR fpAdd` becomes `JSR _fpAdd`. The thunk does the trampoline staging —
    // select the bank, call, restore — so the call site stays a single 3-byte
    // instruction. That size preservation is the whole point: inlining the
    // staging at every call site would push the banked user functions past
    // their 16 KB budget.
    //
    // Only the matching statement on a line is rewritten. One source line can
    // hold several colon-separated statements — inline asm emits things like
    // `LDA #<s : STA $B5 : ... : JSR asc2fp` — and replacing the whole line
    // would drop the pointer staging in front of the call, leaving the callee
    // to run on a garbage operand.
    u32 rewriteCrossBankCalls(Array* sourceLines)
        {
        if (_bankIds == (Map*)0 || _bankIds.allKeys().count() == (u32)0)
            return (u32)0;
        if (_labelBank.allKeys().count() == (u32)0)
            return (u32)0;

        Array* lineIdx = new Array();   // Number@
        Array* lineCalls = new Array(); // Array@ of String@ pairs: mnemonic, operand
        u32 curBank = (u32)0;
        for (u32 i = (u32)0; i < _lines.count(); i = i + (u32)1)
            {
            XaLine* pl = (XaLine*)_lines.get(i);
            // Only a `.bank` region sets a non-zero bank; a plain `.org` — a
            // user bank or main — resets to zero, which still differs from any
            // runtime bank, so its calls do get rewritten.
            if (pl.type() == (u32)LT_BANK)
                {
                String* id = pl.operand() == (String*)0 ? String.withCString("") : pl.operand();
                Object* b = _bankIds.get((Hashable*)id);
                curBank = b == (Object*)0 ? (u32)0 : ((Number*)b).asU32();
                continue;
                }
            if (pl.type() == (u32)LT_ORG)
                {
                curBank = (u32)0;
                continue;
                }
            if (pl.type() != (u32)LT_INSTRUCTION)
                continue;
            if (!pl.mnemonic().equals(String.withCString("JSR")) && !pl.mnemonic().equals(String.withCString("JMP")))
                continue;
            if (pl.operand() == (String*)0)
                continue;
            String* op = XaText.tws(pl.operand());
            Object* targetBank = _labelBank.get((Hashable*)op);
            if (targetBank == (Object*)0)
                continue; // not a banked label
            if (((Number*)targetBank).asU32() == curBank)
                continue; // intra-bank
            u32 srcLine = pl.sourceLine() - (u32)1;
            if (srcLine >= sourceLines.count())
                continue;
            i32 at = indexOfNumber(lineIdx, srcLine);
            if (at < (i32)0)
                {
                lineIdx.add((Object*)Number.withU32(srcLine));
                lineCalls.add((Object*)new Array());
                at = (i32)(lineIdx.count() - (u32)1);
                }
            Array* calls = (Array*)lineCalls.get((u32)at);
            calls.add((Object*)pl.mnemonic());
            calls.add((Object*)op);
            }
        if (lineIdx.count() == (u32)0)
            return (u32)0;

        u32 rewritten = (u32)0;
        for (u32 r = (u32)0; r < lineIdx.count(); r = r + (u32)1)
            {
            u32 at = ((Number*)lineIdx.get(r)).asU32();
            Array* calls = (Array*)lineCalls.get(r);
            String* line = (String*)sourceLines.get(at);
            Array* stmts = line.splitOnByte((u8)':');
            String* out = new String();
            for (u32 si = (u32)0; si < stmts.count(); si = si + (u32)1)
                {
                if (si > (u32)0)
                    out.appendCString(":");
                String* stmt = (String*)stmts.get(si);
                String* t = XaText.tws(stmt);
                String* replacement = (String*)0;
                for (u32 c = (u32)0; c + (u32)1 < calls.count(); c = c + (u32)2)
                    {
                    String* mn = (String*)calls.get(c);
                    String* op = (String*)calls.get(c + (u32)1);
                    String* prefix = new String();
                    prefix.append(mn);
                    prefix.appendCString(" ");
                    if (!t.hasPrefix(prefix))
                        continue;
                    // The operand is the first token after the mnemonic; stop
                    // at whitespace or a `;`, so a trailing comment cannot
                    // defeat the match. An unmatched cross-bank call would
                    // stay a direct jump into an unmapped bank.
                    String* rest = XaText.tws(t.substringFromByte(prefix.byteLength()));
                    String* tok = operandToken(rest);
                    if (!tok.equals(op))
                        continue;
                    replacement = String.withCString(" ");
                    replacement.append(mn);
                    replacement.appendCString(" _");
                    replacement.append(op);
                    break;
                    }
                if (replacement != (String*)0)
                    {
                    out.append(replacement);
                    rewritten = rewritten + (u32)1;
                    }
                else
                    out.append(stmt);
                }
            sourceLines.set(at, (Object*)out);
            }
        return rewritten;
        }

    static i32 indexOfNumber(Array* a, u32 v)
        {
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((Number*)a.get(i)).asU32() == v)
                return (i32)i;
        return (i32)-1;
        }

    static String* operandToken(String* s)
        {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            {
            u8 c = s.byteAt(i);
            if (c == (u8)' ' || c == (u8)'\t' || c == (u8)';')
                return s.substringBytes((u32)0, i);
            }
        return s;
        }

    // ── The whole assembly ───────────────────────────────────────────────
    //
    // Pass 1, then the size-changing rewrite, then pass 1 again — until the
    // line list stops moving. Only then does pass 2 emit bytes. True when
    // there are segments to write.
    bool assemble(Array* sourceLines)
        {
        for (u32 iter = (u32)0; iter < (u32)8; iter = iter + (u32)1)
            {
            _symbols = new Map();
            Xta.mergeInto(_symbols, platformSymbols());
            // The bank-select registers are named symbols so both the generated
            // code and the hand-written runtime can say `__bank_code_reg`
            // rather than a hard-coded address. They come ONLY from the layout;
            // there is deliberately no default, so a banked program that
            // references one the layout never declared fails with an undefined
            // symbol rather than silently aliasing the historical ZP pair.
            if (_codeBankReg != (u32)0)
                _symbols.set((Hashable*)String.withCString("__bank_code_reg"),
                             (Object*)Number.withI64((i64)_codeBankReg));
            if (_dataBankReg != (u32)0)
                _symbols.set((Hashable*)String.withCString("__bank_data_reg"),
                             (Object*)Number.withI64((i64)_dataBankReg));
            Xta.mergeInto(_symbols, _predefines);
            _errors = new Array();
            _warnings = new Array();
            _ambiguousWarned = new Map();
            pass1(sourceLines);
            if (_errors.count() > (u32)0)
                return false;
            // Cross-bank staging runs to completion first and is idempotent —
            // it leaves no `JSR <banked-label>` behind — so it settles in one
            // pass before the long branches are measured. Only ONE rewriter
            // may edit the line list per iteration: both index off the same
            // pass-1 snapshot, so running two would invalidate the second's
            // indices.
            u32 xbank = rewriteCrossBankCalls(sourceLines);
            if (xbank > (u32)0)
                {
                if (_verbose)
                    {
                    String* m = String.withCString("iteration ");
                    m.append(String.withU32(iter + (u32)1));
                    m.appendCString(": staged ");
                    m.append(String.withU32(xbank));
                    m.appendCString(xbank == (u32)1 ? " cross-bank call" : " cross-bank calls");
                    warn(m);
                    }
                continue;
                }
            u32 rewrites = rewriteLongBranches(sourceLines);
            if (rewrites == (u32)0)
                break;
            if (_verbose)
                {
                String* m = String.withCString("iteration ");
                m.append(String.withU32(iter + (u32)1));
                m.appendCString(": rewrote ");
                m.append(String.withU32(rewrites));
                m.appendCString(rewrites == (u32)1 ? " long branch" : " long branches");
                warn(m);
                }
            }
        if (_errors.count() > (u32)0)
            return false;
        pass2();
        return _errors.count() == (u32)0;
        }

    // ── Preprocessing ────────────────────────────────────────────────────
    //
    // Two sub-passes: collect macro definitions and splice in `.include`d
    // files, then expand macro invocations. A macro body runs to the next
    // `.macro` or the next line that starts in column zero.
    Array* _macroNames;   // String@
    Array* _macroParams;  // Array@ of String@
    Array* _macroBodies;  // Array@ of String@
    Array* _includePaths; // String@

    void setIncludePaths(Array* paths)
        {
        _includePaths = paths;
        }

    Array* preprocess(String* source, String* filename)
        {
        if (_macroNames == (Array*)0)
            {
            _macroNames = new Array();
            _macroParams = new Array();
            _macroBodies = new Array();
            }
        Array* rawLines = source.splitOnByte((u8)'\n');
        Array* result = new Array();
        bool inMacro = false;
        i32 curMacro = (i32)-1;

        for (u32 i = (u32)0; i < rawLines.count(); i = i + (u32)1)
            {
            String* rawLine = (String*)rawLines.get(i);
            String* trimmed = XaText.tws(stripComment(rawLine));
            if (inMacro)
                {
                bool startsAnother = trimmed.lowercased().hasPrefix(String.withCString(".macro "));
                bool column0 = trimmed.byteLength() > (u32)0 && !rawLine.hasPrefix(String.withCString(" ")) && !rawLine.hasPrefix(String.withCString("\t"));
                if (startsAnother || column0)
                    inMacro = false;
                else
                    {
                    ((Array*)_macroBodies.get((u32)curMacro)).add((Object*)rawLine);
                    continue;
                    }
                }
            if (trimmed.lowercased().hasPrefix(String.withCString(".macro ")))
                {
                String* rest = XaText.tws(trimmed.substringFromByte((u32)7));
                Array* parts = splitWhitespace(rest);
                String* name = parts.count() > (u32)0 ? (String*)parts.get((u32)0) : String.withCString("");
                _macroNames.add((Object*)name);
                Array* params = new Array();
                if (parts.count() > (u32)1)
                    {
                    String* paramStr = XaText.tws(rest.substringFromByte(name.byteLength()));
                    Array* ps = paramStr.splitOnByte((u8)',');
                    for (u32 k = (u32)0; k < ps.count(); k = k + (u32)1)
                        {
                        String* t = XaText.tws((String*)ps.get(k));
                        if (t.byteLength() > (u32)0)
                            params.add((Object*)t);
                        }
                    }
                _macroParams.add((Object*)params);
                _macroBodies.add((Object*)new Array());
                curMacro = (i32)(_macroNames.count() - (u32)1);
                inMacro = true;
                continue;
                }
            if (trimmed.lowercased().hasPrefix(String.withCString(".include ")))
                {
                String* inc = XaText.twsn(trimmed.substringFromByte((u32)9));
                if ((inc.hasPrefix(String.withCString("\"")) && inc.hasSuffix(String.withCString("\""))) || (inc.hasPrefix(String.withCString("<")) && inc.hasSuffix(String.withCString(">"))))
                    inc = inc.substringBytes((u32)1, inc.byteLength() - (u32)2);
                String* content = readInclude(inc, filename);
                if (content != (String*)0)
                    {
                    Array* incLines = preprocess(content, inc);
                    for (u32 k = (u32)0; k < incLines.count(); k = k + (u32)1)
                        result.add(incLines.get(k));
                    }
                continue;
                }
            result.add((Object*)rawLine);
            }
        return expandMacros(result);
        }

    Array* expandMacros(Array* result)
        {
        Array* expanded = new Array();
        for (u32 i = (u32)0; i < result.count(); i = i + (u32)1)
            {
            String* rawLine = (String*)result.get(i);
            String* trimmed = XaText.tws(stripComment(rawLine));
            String* afterLabel = trimmed;
            bool hadLabel = false;
            u32 colon = trimmed.byteIndexOf(String.withCString(":"));
            if (colon != (u32)$FFFF_FFFF && colon < (u32)20)
                {
                String* before = XaText.tws(trimmed.substringBytes((u32)0, colon));
                if (isValidIdentifier(before))
                    {
                    afterLabel = XaText.tws(trimmed.substringFromByte(colon + (u32)1));
                    hadLabel = true;
                    }
                }
            Array* words = splitWhitespace(afterLabel);
            i32 mi = (i32)-1;
            if (words.count() > (u32)0)
                mi = macroIndex((String*)words.get((u32)0));
            if (mi >= (i32)0)
                {
                if (hadLabel)
                    expanded.add((Object*)trimmed.substringBytes((u32)0, colon + (u32)1));
                String* name = (String*)words.get((u32)0);
                String* args = afterLabel.byteLength() > name.byteLength()
                                   ? XaText.tws(afterLabel.substringFromByte(name.byteLength()))
                                   : String.withCString("");
                Array* body = expandMacro((u32)mi, args);
                for (u32 k = (u32)0; k < body.count(); k = k + (u32)1)
                    expanded.add(body.get(k));
                continue;
                }
            expanded.add((Object*)rawLine);
            }
        return expanded;
        }

    // The LAST definition of a name wins, as a redefinition replaces it.
    i32 macroIndex(String* name)
        {
        if (_macroNames == (Array*)0 || name.byteLength() == (u32)0)
            return (i32)-1;
        i32 found = (i32)-1;
        for (u32 i = (u32)0; i < _macroNames.count(); i = i + (u32)1)
            if (((String*)_macroNames.get(i)).equals(name))
                found = (i32)i;
        return found;
        }

    Array* expandMacro(u32 mi, String* argsStr)
        {
        Array* argValues = new Array();
        if (argsStr.byteLength() > (u32)0)
            {
            Array* as = argsStr.splitOnByte((u8)',');
            for (u32 i = (u32)0; i < as.count(); i = i + (u32)1)
                argValues.add((Object*)XaText.tws((String*)as.get(i)));
            }
        Array* params = (Array*)_macroParams.get(mi);
        Array* body = (Array*)_macroBodies.get(mi);
        Array* out = new Array();
        for (u32 i = (u32)0; i < body.count(); i = i + (u32)1)
            {
            String* line = (String*)body.get(i);
            for (u32 k = (u32)0; k < params.count() && k < argValues.count(); k = k + (u32)1)
                line = replaceAll(line, (String*)params.get(k), (String*)argValues.get(k));
            out.add((Object*)line);
            }
        return out;
        }

    static String* replaceAll(String* s, String* from, String* to)
        {
        if (from.byteLength() == (u32)0)
            return s;
        String* out = new String();
        u32 i = (u32)0;
        while (i < s.byteLength())
            {
            if (i + from.byteLength() <= s.byteLength() && s.substringBytes(i, from.byteLength()).equals(from))
                {
                out.append(to);
                i = i + from.byteLength();
                continue;
                }
            out.appendByte(s.byteAt(i));
            i = i + (u32)1;
            }
        return out;
        }

    String* readInclude(String* filename, String* currentFile)
        {
        Array* paths = new Array();
        paths.add((Object*)dirOf(currentFile));
        if (_includePaths != (Array*)0)
            for (u32 i = (u32)0; i < _includePaths.count(); i = i + (u32)1)
                paths.add(_includePaths.get(i));
        for (u32 i = (u32)0; i < paths.count(); i = i + (u32)1)
            {
            String* dir = (String*)paths.get(i);
            String* full = new String();
            if (dir.byteLength() > (u32)0)
                {
                full.append(dir);
                full.appendCString("/");
                }
            full.append(filename);
            String* content = Files.readText(full);
            if (content != (String*)0 && XaText.isUtf8(content))
                return content;
            }
        String* m = String.withCString("Cannot find include file '");
        m.append(filename);
        m.appendCString("'");
        err(m);
        return (String*)0;
        }

    static String* dirOf(String* path)
        {
        u32 last = (u32)$FFFF_FFFF;
        for (u32 i = (u32)0; i < path.byteLength(); i = i + (u32)1)
            if (path.byteAt(i) == (u8)'/')
                last = i;
        if (last == (u32)$FFFF_FFFF)
            return String.withCString("");
        if (last == (u32)0)
            return String.withCString("/");
        return path.substringBytes((u32)0, last);
        }

    // ── Listing ──────────────────────────────────────────────────────────
    //
    // The address beside each source line of the last assembly.
    String* listing(void)
        {
        String* out = new String();
        u32 pc = (u32)0;
        for (u32 i = (u32)0; i < _lines.count(); i = i + (u32)1)
            {
            XaLine* pl = (XaLine*)_lines.get(i);
            String* raw = pl.rawText() == (String*)0 ? String.withCString("") : pl.rawText();
            u32 t = pl.type();
            if (t == (u32)LT_ORG)
                {
                pc = (u32)evaluate(pl.operand()) & (u32)$FFFF;
                out.appendCString("       ");
                out.append(XaText.hex4(pc));
                out.appendCString("          ");
                }
            else if (emitsBytes(pl))
                {
                out.appendCString("  ");
                out.append(XaText.hex4(pc));
                out.appendCString("               ");
                pc = (pc + pl.byteSize()) & (u32)$FFFF;
                }
            else
                out.appendCString("                     ");
            out.append(raw);
            out.appendCString("\n");
            }
        return out;
        }

    // ── Output ───────────────────────────────────────────────────────────
    //
    // An Atari executable is `$FFFF` then a run of (start, end, bytes) blocks,
    // and finally a RUNAD block writing the entry address to $02E0 — which the
    // loader treats as "jump here when everything is in". Each writer returns
    // the image, or null after reporting why it cannot be written.
    static void addByte(Array* xex, u32 v)
        {
        xex.add((Object*)Number.withU32(v & (u32)$FF));
        }

    static void addBlock(Array* xex, u32 start, u32 end)
        {
        Xta.addByte(xex, start);
        Xta.addByte(xex, start >> (u32)8);
        Xta.addByte(xex, end);
        Xta.addByte(xex, end >> (u32)8);
        }

    static void addAll(Array* dst, Array* src)
        {
        for (u32 i = (u32)0; i < src.count(); i = i + (u32)1)
            dst.add(src.get(i));
        }

    static void addRunad(Array* xex, u32 entry)
        {
        Xta.addByte(xex, (u32)$E0);
        Xta.addByte(xex, (u32)$02);
        Xta.addByte(xex, (u32)$E1);
        Xta.addByte(xex, (u32)$02);
        Xta.addByte(xex, entry);
        Xta.addByte(xex, entry >> (u32)8);
        }

    // INITAD ($02E2) pointing at the cassette buffer.
    static void addInitad(Array* xex)
        {
        Xta.addByte(xex, (u32)$E2);
        Xta.addByte(xex, (u32)$02);
        Xta.addByte(xex, (u32)$E3);
        Xta.addByte(xex, (u32)$02);
        Xta.addByte(xex, (u32)$FD);
        Xta.addByte(xex, (u32)$03);
        }

    static void report(String* m)
        {
        Stdio.error(m);
        }

    // A segment split around the shadow ranges: the bytes outside go to
    // mainPieces, the bytes inside to shadowPieces, each as (address, bytes).
    void splitMainSegment(XaSegment* seg, Array* mainPieces, Array* shadowPieces)
        {
        Array* data = seg.data();
        u32 segStart = seg.origin();
        u32 segEnd = segStart + data.count() - (u32)1;
        if (_shadowRanges == (Array*)0 || _shadowRanges.count() == (u32)0 || _shadowStageBase == (u32)0)
            {
            mainPieces.add((Object*)Number.withU32(segStart));
            mainPieces.add((Object*)data);
            return;
            }
        Array* ovLo = new Array();
        Array* ovHi = new Array();
        for (u32 i = (u32)0; i + (u32)1 < _shadowRanges.count(); i = i + (u32)2)
            {
            u32 rs = ((Number*)_shadowRanges.get(i)).asU32();
            u32 re = ((Number*)_shadowRanges.get(i + (u32)1)).asU32();
            if (re < segStart || rs > segEnd)
                continue;
            u32 lo = rs > segStart ? rs : segStart;
            u32 hi = re < segEnd ? re : segEnd;
            // Kept sorted by start as they arrive.
            u32 at = ovLo.count();
            while (at > (u32)0 && ((Number*)ovLo.get(at - (u32)1)).asU32() > lo)
                at = at - (u32)1;
            ovLo.insert(at, (Object*)Number.withU32(lo));
            ovHi.insert(at, (Object*)Number.withU32(hi));
            }
        if (ovLo.count() == (u32)0)
            {
            mainPieces.add((Object*)Number.withU32(segStart));
            mainPieces.add((Object*)data);
            return;
            }
        u32 cursor = segStart;
        for (u32 i = (u32)0; i < ovLo.count(); i = i + (u32)1)
            {
            u32 lo = ((Number*)ovLo.get(i)).asU32();
            u32 hi = ((Number*)ovHi.get(i)).asU32();
            if (cursor < lo)
                {
                mainPieces.add((Object*)Number.withU32(cursor & (u32)$FFFF));
                mainPieces.add((Object*)Xta.slice(data, cursor - segStart, lo - cursor));
                }
            shadowPieces.add((Object*)Number.withU32(lo & (u32)$FFFF));
            shadowPieces.add((Object*)Xta.slice(data, lo - segStart, hi - lo + (u32)1));
            cursor = hi + (u32)1;
            }
        if (cursor <= segEnd)
            {
            mainPieces.add((Object*)Number.withU32(cursor & (u32)$FFFF));
            mainPieces.add((Object*)Xta.slice(data, cursor - segStart, segEnd - cursor + (u32)1));
            }
        }

    static Array* slice(Array* a, u32 from, u32 len)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < len; i = i + (u32)1)
            out.add(a.get(from + i));
        return out;
        }

    // The shadow staging segment at `.shadow_stage`: a 109-byte copy stub,
    // then a table of (src, dst, len) entries ending in six zeros, then the
    // bytes. INITAD points at the stub, so the loader copies them into the RAM
    // under the ROM as soon as the segment lands.
    bool appendShadowStaging(Array* xex, Array* shadowPieces)
        {
        u32 stageBase = _shadowStageBase;
        u32 numEntries = shadowPieces.count() / (u32)2;
        u32 stubSize = (u32)$6D;
        u32 tableSize = (numEntries + (u32)1) * (u32)6;
        u32 dataStart = stubSize + tableSize;
        u32 totalPayload = (u32)0;
        for (u32 i = (u32)0; i < numEntries; i = i + (u32)1)
            totalPayload = totalPayload + ((Array*)shadowPieces.get(i * (u32)2 + (u32)1)).count();
        u32 stageEnd32 = stageBase + dataStart + totalPayload;
        if (stageEnd32 > (u32)$8000)
            {
            String* m = String.withCString("xcc-as: warning: shadow staging segment $");
            m.append(XaText.hex4(stageBase));
            m.appendCString("-$");
            m.append(XaText.hex4(stageEnd32 - (u32)1));
            m.appendCString(" extends ");
            m.append(String.withU32(stageEnd32 - (u32)$8000));
            m.appendCString(" bytes into screen RAM at $8000. The XEX loader writes staging bytes there during load. The xl-shadow startup template clears screen RAM at boot after the staging stub finishes, so ANTIC won't read stale bytes — but tighter shadow code (`-O2` / `-O3`) would avoid the overlap entirely.\n");
            Xta.report(m);
            }

        Array* table = new Array();
        u32 dataOffset = (u32)0;
        for (u32 i = (u32)0; i < numEntries; i = i + (u32)1)
            {
            u32 target = ((Number*)shadowPieces.get(i * (u32)2)).asU32();
            Array* d = (Array*)shadowPieces.get(i * (u32)2 + (u32)1);
            u32 len = d.count() & (u32)$FFFF;
            u32 src32 = stageBase + dataStart + dataOffset;
            if (src32 > (u32)$FFFF)
                {
                String* m = String.withCString("xcc-as: shadow staging payload at $");
                m.append(XaText.hex4(stageBase));
                m.appendCString(" overflows 64 KB (would extend past $FFFF). Reduce shadow-region code size or move .shadow_stage lower.\n");
                Xta.report(m);
                return false;
                }
            Xta.addByte(table, src32);
            Xta.addByte(table, src32 >> (u32)8);
            Xta.addByte(table, target);
            Xta.addByte(table, target >> (u32)8);
            Xta.addByte(table, len);
            Xta.addByte(table, len >> (u32)8);
            dataOffset = dataOffset + d.count();
            }
        for (u32 k = (u32)0; k < (u32)6; k = k + (u32)1)
            Xta.addByte(table, (u32)0);

        u32 tableAddr = (stageBase + stubSize) & (u32)$FFFF;
        u32 nextEntry = (stageBase + (u32)$11) & (u32)$FFFF;
        u32 tlo = tableAddr & (u32)$FF;
        u32 thi = tableAddr >> (u32)8;
        Array* stub = new Array();
        Xta.addHex(stub, "08 78 A9 00 8D 0E D4 AD 01 D3 29 FE 8D 01 D3 A2 00");
        for (u32 k = (u32)0; k < (u32)6; k = k + (u32)1)
            {
            Xta.addByte(stub, (u32)$BD);
            Xta.addByte(stub, tlo);
            Xta.addByte(stub, thi);
            Xta.addByte(stub, (u32)$85);
            Xta.addByte(stub, (u32)$C0 + k);
            Xta.addByte(stub, (u32)$E8);
            }
        Xta.addHex(stub, "A5 C4 05 C5 F0 23 A0 00 B1 C0 91 C2 E6 C0 D0 02 E6 C1 E6 C2 D0 02 E6 C3 A5 C4 D0 02 C6 C5 C6 C4 A5 C4 05 C5 D0 E0 4C");
        Xta.addByte(stub, nextEntry);
        Xta.addByte(stub, nextEntry >> (u32)8);
        Xta.addHex(stub, "AD 01 D3 09 01 8D 01 D3 A9 40 8D 0E D4 28 60");
        if (stub.count() != stubSize)
            {
            String* m = String.withCString("xcc-as: internal: shadow copy stub size mismatch (got ");
            m.append(String.withU32(stub.count()));
            m.appendCString(", expected ");
            m.append(String.withU32(stubSize));
            m.appendCString(")\n");
            Xta.report(m);
            return false;
            }

        Array* payload = new Array();
        Xta.addAll(payload, stub);
        Xta.addAll(payload, table);
        for (u32 i = (u32)0; i < numEntries; i = i + (u32)1)
            Xta.addAll(payload, (Array*)shadowPieces.get(i * (u32)2 + (u32)1));
        u32 stageEnd = stageBase + payload.count() - (u32)1;
        if (stageEnd > (u32)$FFFF)
            {
            String* m = String.withCString("xcc-as: shadow staging payload at $");
            m.append(XaText.hex4(stageBase));
            m.appendCString(" is ");
            m.append(String.withU32(payload.count()));
            m.appendCString(" bytes, runs past $FFFF. Reduce shadow-region code size or pick a lower stage address.\n");
            Xta.report(m);
            return false;
            }
        Xta.addBlock(xex, stageBase, stageEnd);
        Xta.addAll(xex, payload);
        Xta.addByte(xex, (u32)$E2);
        Xta.addByte(xex, (u32)$02);
        Xta.addByte(xex, (u32)$E3);
        Xta.addByte(xex, (u32)$02);
        Xta.addByte(xex, stageBase);
        Xta.addByte(xex, stageBase >> (u32)8);
        return true;
        }

    // Bytes spelled as hex pairs separated by spaces: "AD 01 D3".
    static void addHex(Array* a, string text)
        {
        String* s = String.withCString(text);
        u32 i = (u32)0;
        while (i + (u32)1 < s.byteLength())
            {
            i32 hi = XaText.hexDigit(s.byteAt(i));
            i32 lo = XaText.hexDigit(s.byteAt(i + (u32)1));
            if (hi >= (i32)0 && lo >= (i32)0)
                {
                a.add((Object*)Number.withU32((u32)(hi * (i32)16 + lo)));
                i = i + (u32)2;
                continue;
                }
            i = i + (u32)1;
            }
        }

    Array* writeXex(u32 entry)
        {
        Array* xex = new Array();
        Xta.addByte(xex, (u32)$FF);
        Xta.addByte(xex, (u32)$FF);
        Array* mainPieces = new Array();
        Array* shadowPieces = new Array();
        for (u32 i = (u32)0; i < _segments.count(); i = i + (u32)1)
            {
            XaSegment* seg = (XaSegment*)_segments.get(i);
            if (seg.data().count() == (u32)0)
                continue;
            splitMainSegment(seg, mainPieces, shadowPieces);
            }
        for (u32 i = (u32)0; i + (u32)1 < mainPieces.count(); i = i + (u32)2)
            {
            u32 start = ((Number*)mainPieces.get(i)).asU32();
            Array* d = (Array*)mainPieces.get(i + (u32)1);
            Xta.addBlock(xex, start, start + d.count() - (u32)1);
            Xta.addAll(xex, d);
            }
        if (shadowPieces.count() > (u32)0 && !appendShadowStaging(xex, shadowPieces))
            return (Array*)0;
        Xta.addRunad(xex, entry);
        return xex;
        }

    // A C64 PRG: the load address, then every segment flattened in address
    // order with the gaps zero-filled.
    Array* writePrg(void)
        {
        Array* sorted = new Array();
        for (u32 i = (u32)0; i < _segments.count(); i = i + (u32)1)
            {
            XaSegment* seg = (XaSegment*)_segments.get(i);
            if (seg.data().count() == (u32)0)
                continue;
            u32 at = sorted.count();
            while (at > (u32)0 && ((XaSegment*)sorted.get(at - (u32)1)).origin() > seg.origin())
                at = at - (u32)1;
            sorted.insert(at, (Object*)seg);
            }
        if (sorted.count() == (u32)0)
            return (Array*)0;
        u32 loadAddr = ((XaSegment*)sorted.get((u32)0)).origin();
        u32 cursor = loadAddr;
        Array* prg = new Array();
        Xta.addByte(prg, loadAddr);
        Xta.addByte(prg, loadAddr >> (u32)8);
        for (u32 i = (u32)0; i < sorted.count(); i = i + (u32)1)
            {
            XaSegment* seg = (XaSegment*)sorted.get(i);
            while (cursor < seg.origin())
                {
                Xta.addByte(prg, (u32)0);
                cursor = cursor + (u32)1;
                }
            Xta.addAll(prg, seg.data());
            cursor = (seg.origin() + seg.data().count()) & (u32)$FFFF;
            }
        return prg;
        }

    // ── Banked XEX output ────────────────────────────────────────────────
    //
    // A banked segment cannot simply be loaded: the window shows whichever
    // bank the selector register names, so the loader has to SELECT the bank
    // before the bytes stream in. The trick is INITAD — the Atari loader jumps
    // to whatever address sits at $02E2 after each segment — so each banked
    // segment is preceded by a tiny stub in the cassette buffer that writes the
    // bank register, an INITAD pointing at it, and a re-load of the same bytes
    // to fire it. Then the payload lands in the right page.
    //
    // The stub is idempotent, so re-loading it to trigger the fire is harmless.
    u32 _bankWindowStart;
    u32 _bankWindowEnd;
    u32 _dataWindowStart;
    u32 _dataWindowEnd;
    bool _hasSplitBanking;

    void setBankWindow(u32 lo, u32 hi)
        {
        _bankWindowStart = lo;
        _bankWindowEnd = hi;
        }
    // Recording the data window does NOT by itself mean split banking: the xt
    // layout has two windows but ONE joint selector pair (low byte to the code
    // register, high byte to the data one). Split mode — two independent 8-bit
    // selectors — is a separate decision the layout makes.
    void setDataWindow(u32 lo, u32 hi)
        {
        _dataWindowStart = lo;
        _dataWindowEnd = hi;
        }
    void setSplitBanking(bool v)
        {
        _hasSplitBanking = v;
        }

    // `LDA #v / STA <reg>` — zero page when the register fits, absolute
    // otherwise, because a layout may put the selector outside ZP (xt does:
    // $D5C0 and $D5C1).
    static void emitBankRegStore(Array* out, u32 addr)
        {
        if (addr <= (u32)$FF)
            {
            Xta.addByte(out, (u32)$85);
            Xta.addByte(out, addr);
            return;
            }
        Xta.addByte(out, (u32)$8D);
        Xta.addByte(out, addr);
        Xta.addByte(out, addr >> (u32)8);
        }

    // Load a stub at the cassette buffer, point INITAD at it, and load it
    // again so it fires.
    static void addFiredStub(Array* xex, Array* stub)
        {
        u32 stubAddr = (u32)$03FD;
        u32 stubEnd = stubAddr + stub.count() - (u32)1;
        Xta.addBlock(xex, stubAddr, stubEnd);
        Xta.addAll(xex, stub);
        Xta.addInitad(xex);
        Xta.addBlock(xex, stubAddr, stubEnd);
        Xta.addAll(xex, stub);
        }

    Array* writeBankedXex(u32 entry)
        {
        Array* xex = new Array();
        Xta.addByte(xex, (u32)$FF);
        Xta.addByte(xex, (u32)$FF);

        u32 bwStart = _bankWindowStart != (u32)0 ? _bankWindowStart : (u32)$4000;
        u32 bwEnd = _bankWindowEnd != (u32)0 ? _bankWindowEnd : (u32)$7FFF;
        Array* mainSegs = new Array();
        Array* bankedSegs = new Array();
        u32 cloakedNone = (u32)0;
        u32 cloakedNumbered = (u32)0;
        for (u32 i = (u32)0; i < _segments.count(); i = i + (u32)1)
            {
            XaSegment* seg = (XaSegment*)_segments.get(i);
            if (seg.isCloaked())
                {
                if (seg.cloakedBankIndex() < (i32)0)
                    cloakedNone = cloakedNone + (u32)1;
                else
                    cloakedNumbered = cloakedNumbered + (u32)1;
                }
            else if (seg.origin() >= bwStart && seg.origin() <= bwEnd)
                bankedSegs.add((Object*)seg);
            else
                mainSegs.add((Object*)seg);
            }

        // The main segments split around the shadow ranges now, so the
        // staging is known before anything else is emitted.
        Array* mainPieces = new Array();
        Array* shadowPieces = new Array();
        for (u32 i = (u32)0; i < mainSegs.count(); i = i + (u32)1)
            {
            XaSegment* seg = (XaSegment*)mainSegs.get(i);
            if (seg.data().count() == (u32)0)
                continue;
            splitMainSegment(seg, mainPieces, shadowPieces);
            }

        if (shadowPieces.count() > (u32)0)
            {
            // Banking off first (a 9-byte stub at the cassette buffer), then
            // the staging segment, a re-load that fires its copy stub, and
            // INITAD put back on the harmless banking-off stub.
            Array* off = new Array();
            Xta.addHex(off, "AD 01 D3 09 10 8D 01 D3 60");
            Xta.addFiredStub(xex, off);
            if (!appendShadowStaging(xex, shadowPieces))
                return (Array*)0;
            Xta.addBlock(xex, (u32)$03FD, (u32)$0405);
            Xta.addAll(xex, off);
            Xta.addInitad(xex);
            Xta.addBlock(xex, (u32)$03FD, (u32)$0405);
            Xta.addAll(xex, off);
            }

        // Cloaked code needs the PORTB banking of the xe family, which no
        // layout this assembler reads selects.
        if (cloakedNone > (u32)0)
            {
            String* m = String.withCString("xcc-as: cloaked segments are only supported on xe-family targets (xeBankMask = 0); ignoring ");
            m.append(String.withU32(cloakedNone));
            m.appendCString(" segment(s)\n");
            Xta.report(m);
            }
        if (cloakedNumbered > (u32)0)
            {
            String* m = String.withCString("xcc-as: numbered-bank cloaked segments are only supported on xe-family targets (xeBankMask = 0); ignoring ");
            m.append(String.withU32(cloakedNumbered));
            m.appendCString(" segment(s)\n");
            Xta.report(m);
            }

        u32 codeBankPage = (u32)1;
        u32 dataBankPage = (u32)1;
        u32 regCBankPage = (u32)1;
        u32 bankPage = (u32)1;
        i32 hiState = (i32)-1;
        // No $82/$83 fallback — the bank registers come from the layout.
        if (bankedSegs.count() > (u32)0 && _codeBankReg == (u32)0)
            {
            Xta.report(String.withCString("xcc-as: banked output requires a code bank register from the layout (registers = <code>, <data>); none set — there is no $82 default\n"));
            return (Array*)0;
            }
        bool hasRegCWindow = _regCWindowStart != (u32)0 && _regCBankRegLo != (u32)0;

        for (u32 i = (u32)0; i < bankedSegs.count(); i = i + (u32)1)
            {
            XaSegment* bseg = (XaSegment*)bankedSegs.get(i);
            // A region-C segment routes through its own selector(s) and page
            // counter; under split banking a data-window segment through the
            // data selector; everything else through the code selector.
            bool isRegCSeg = hasRegCWindow && bseg.origin() >= _regCWindowStart && bseg.origin() <= _regCWindowEnd;
            bool isDataSeg = !isRegCSeg && _hasSplitBanking && bseg.origin() >= _dataWindowStart && bseg.origin() <= _dataWindowEnd;
            // An EMPTY banked segment is a placeholder bank-page anchor: at
            // -O3 the optimiser can inline away every function on a page and
            // leave the `.org` behind. It emits no bytes, but it still BURNS a
            // page number, so later classes stay on the bank their call sites
            // were compiled against.
            if (bseg.data().count() == (u32)0)
                {
                if (isRegCSeg)
                    regCBankPage = (regCBankPage + (u32)1) & (u32)$FFFF;
                else if (_hasSplitBanking)
                    {
                    if (isDataSeg)
                        dataBankPage = (dataBankPage + (u32)1) & (u32)$FFFF;
                    else
                        codeBankPage = (codeBankPage + (u32)1) & (u32)$FFFF;
                    }
                else
                    bankPage = (bankPage + (u32)1) & (u32)$FFFF;
                continue;
                }

            u32 bankPageSz = bwEnd - bwStart + (u32)1;
            if (bseg.data().count() > bankPageSz)
                {
                String* m = String.withCString("xcc-as: banked segment at $");
                m.append(XaText.hex4(bseg.origin()));
                m.appendCString(" is ");
                m.append(String.withU32(bseg.data().count()));
                m.appendCString(" bytes — exceeds the ");
                m.append(String.withU32(bankPageSz));
                m.appendCString("B bank page size\n");
                Xta.report(m);
                return (Array*)0;
                }
            if (_hasSplitBanking)
                {
                u32 codeStart = _bankWindowStart != (u32)0 ? _bankWindowStart : bwStart;
                u32 codeEnd = _dataWindowStart != (u32)0 ? ((_dataWindowStart - (u32)1) & (u32)$FFFF) : bwEnd;
                if (isDataSeg)
                    {
                    u32 half = _dataWindowEnd - _dataWindowStart + (u32)1;
                    if (bseg.data().count() > half)
                        {
                        String* m = String.withCString("xcc-as: banked data segment at $");
                        m.append(XaText.hex4(bseg.origin()));
                        m.appendCString(" is ");
                        m.append(String.withU32(bseg.data().count()));
                        m.appendCString(" bytes — exceeds the ");
                        m.append(String.withU32(half));
                        m.appendCString("B split-bank data half ($");
                        m.append(XaText.hex4(_dataWindowStart));
                        m.appendCString("-$");
                        m.append(XaText.hex4(_dataWindowEnd));
                        m.appendCString("). Code likely overflowed the code half and bled into the data window; rebuild with -O3 (smaller main) or split the function across banks.\n");
                        Xta.report(m);
                        return (Array*)0;
                        }
                    }
                else if (!isRegCSeg)
                    {
                    u32 half = codeEnd - codeStart + (u32)1;
                    if (bseg.data().count() > half)
                        {
                        String* m = String.withCString("xcc-as: banked code segment at $");
                        m.append(XaText.hex4(bseg.origin()));
                        m.appendCString(" is ");
                        m.append(String.withU32(bseg.data().count()));
                        m.appendCString(" bytes — exceeds the ");
                        m.append(String.withU32(half));
                        m.appendCString("B split-bank code half ($");
                        m.append(XaText.hex4(codeStart));
                        m.appendCString("-$");
                        m.append(XaText.hex4(codeEnd));
                        m.appendCString("). The packer's size estimate drifted from xta's actual emit (often a long-branch rewrite inside a function); the segment overflows into the $83-selected data window where the per-bank XEX preload would put unrelated bytes at runtime, and JMP/JSR/branch into the overflow BRKs.\n");
                        Xta.report(m);
                        return (Array*)0;
                        }
                    }
                }

            // An explicit `.bank` number overrides the running counter; the
            // counter still advances, so a later auto-numbered segment stays
            // correctly numbered.
            u32 effBankPage = bseg.bankNumber() >= (i32)0 ? ((u32)bseg.bankNumber() & (u32)$FFFF) : bankPage;
            u32 thisPage = isRegCSeg ? regCBankPage
                                     : (_hasSplitBanking ? (isDataSeg ? dataBankPage : codeBankPage)
                                                         : effBankPage);

            Array* stub = new Array();
            if (isRegCSeg)
                {
                Xta.addByte(stub, (u32)$A9);
                Xta.addByte(stub, thisPage);
                Xta.emitBankRegStore(stub, _regCBankRegLo);
                if (_regCBankRegHi != (u32)0)
                    {
                    Xta.addByte(stub, (u32)$A9);
                    Xta.addByte(stub, thisPage >> (u32)8);
                    Xta.emitBankRegStore(stub, _regCBankRegHi);
                    }
                Xta.addByte(stub, (u32)$60);
                }
            else if (_hasSplitBanking)
                {
                // Split windows: write only the selector for this segment's
                // half. Code and data are fully independent under split mode,
                // so a code-side stub must not disturb the data bank.
                Xta.addByte(stub, (u32)$A9);
                Xta.addByte(stub, thisPage);
                Xta.emitBankRegStore(stub, isDataSeg ? _dataBankReg : _codeBankReg);
                Xta.addByte(stub, (u32)$60);
                }
            else
                {
                // Joint selector: low byte to the code register, high byte to
                // the data one. An 8-bit page never sets the high byte, so
                // that write stays dormant — and tracking it across segments
                // lets the stub drop to five bytes after the first.
                u32 hi = (effBankPage >> (u32)8) & (u32)$FF;
                Xta.addByte(stub, (u32)$A9);
                Xta.addByte(stub, effBankPage);
                Xta.emitBankRegStore(stub, _codeBankReg);
                if ((i32)hi != hiState)
                    {
                    Xta.addByte(stub, (u32)$A9);
                    Xta.addByte(stub, hi);
                    Xta.emitBankRegStore(stub, _dataBankReg);
                    hiState = (i32)hi;
                    }
                Xta.addByte(stub, (u32)$60);
                }
            Xta.addFiredStub(xex, stub);

            u32 loadStart = bseg.origin();
            u32 loadEnd = (loadStart + bseg.data().count() - (u32)1) & (u32)$FFFF;
            Xta.addBlock(xex, loadStart, loadEnd);
            Xta.addAll(xex, bseg.data());

            // Reset the selector before whatever loads next, so a later
            // banked segment's stub does not run against a stale bank.
            Array* reset = new Array();
            if (isRegCSeg)
                {
                Xta.addByte(reset, (u32)$A9);
                Xta.addByte(reset, (u32)0);
                Xta.emitBankRegStore(reset, _regCBankRegLo);
                if (_regCBankRegHi != (u32)0)
                    Xta.emitBankRegStore(reset, _regCBankRegHi);
                Xta.addByte(reset, (u32)$60);
                }
            else if (_hasSplitBanking)
                {
                Xta.addByte(reset, (u32)$A9);
                Xta.addByte(reset, (u32)0);
                Xta.emitBankRegStore(reset, isDataSeg ? _dataBankReg : _codeBankReg);
                Xta.addByte(reset, (u32)$60);
                }
            else
                {
                Xta.addByte(reset, (u32)$A9);
                Xta.addByte(reset, (u32)0);
                Xta.emitBankRegStore(reset, _codeBankReg);
                if (hiState != (i32)0)
                    {
                    Xta.emitBankRegStore(reset, _dataBankReg);
                    hiState = (i32)0;
                    }
                Xta.addByte(reset, (u32)$60);
                }
            Xta.addFiredStub(xex, reset);

            if (isRegCSeg)
                regCBankPage = (regCBankPage + (u32)1) & (u32)$FFFF;
            else if (_hasSplitBanking)
                {
                if (isDataSeg)
                    dataBankPage = (dataBankPage + (u32)1) & (u32)$FFFF;
                else
                    codeBankPage = (codeBankPage + (u32)1) & (u32)$FFFF;
                }
            else
                bankPage = (bankPage + (u32)1) & (u32)$FFFF;
            }

        // The main pieces — those outside every shadow range — last, each
        // checked against the main region.
        u32 mrStart = _mainRegionStart != (u32)0 ? _mainRegionStart : (u32)$A000;
        u32 mrEnd = _mainRegionEnd != (u32)0 ? _mainRegionEnd : (u32)$BFFF;
        for (u32 i = (u32)0; i + (u32)1 < mainPieces.count(); i = i + (u32)2)
            {
            u32 start = ((Number*)mainPieces.get(i)).asU32();
            Array* d = (Array*)mainPieces.get(i + (u32)1);
            u32 end32 = start + d.count() - (u32)1;
            if (start >= mrStart && start <= mrEnd && end32 > mrEnd)
                {
                String* m = String.withCString("xcc-as: main code segment at $");
                m.append(XaText.hex4(start));
                m.appendCString(" is ");
                m.append(String.withU32(d.count()));
                m.appendCString(" bytes — overflows the ");
                m.append(String.withU32(mrEnd - mrStart + (u32)1));
                m.appendCString("B main region ($");
                m.append(XaText.hex4(mrStart));
                m.appendCString("-$");
                m.append(XaText.hex4(mrEnd));
                m.appendCString(") by ");
                m.append(String.withU32(end32 - mrEnd));
                m.appendCString(" bytes. The program will load under xts (flat 64 KB) but crash on real hardware.\n");
                Xta.report(m);
                return (Array*)0;
                }
            Xta.addBlock(xex, start, end32);
            Xta.addAll(xex, d);
            }

        Xta.addRunad(xex, entry);
        return xex;
        }
    }
