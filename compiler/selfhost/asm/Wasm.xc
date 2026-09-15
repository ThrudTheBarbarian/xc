// Wasm.xc — assemble xcc-cg-wasm32's WAT dialect into a .wasm binary.
// ===================================================================
//
// self-hosting, wasm stage B. The port of `XTWasmWriter`: the input is NOT
// general s-expression WAT, it is the known, linear dialect the back end
// emits — header forms `(import …)` / `(memory …)` / `(global …)` / `(data …)`,
// then `(func …)` bodies of one instruction per line. Section framing is
// LEB128 and a self-contained module has NO relocations, which is what makes
// an in-house assembler small. The `name` custom section is emitted so
// browser stack traces stay legible.
//
// The ORACLE is `xcc-ln-wasm32` over the same WAT text — the bytes must come
// out identical (lnwasm-diff.sh). Structure note: the original is three big
// methods; this port splits parsing and emission per form/section, both for
// readability and because the arm64 frame budget caps how many owned temps
// one function may hold. The keyword strings are interned once in init for
// the same reason.

#import "Foundation.xc"

// Immediate styles — the WImm enum of the original, same numbering.
#define WIMM_NONE 0
#define WIMM_I32 1
#define WIMM_I64 2
#define WIMM_F32 3
#define WIMM_F64 4
#define WIMM_LABEL 5
#define WIMM_LOCAL 6
#define WIMM_GLOBAL 7
#define WIMM_CALL 8
#define WIMM_BRTABLE 9
#define WIMM_MEM 10
#define WIMM_MEMPAIR 11
#define WIMM_LANE 12
#define WIMM_LANES16 13

// ── Byte buffer: LEB128 / byte emission over a Data ────────────────────────
class WasmBuf
    {
    Data* _d;

    void init(void)
        {
        _d = Data.withCapacity((u32)0);
        }

    Data* buf(void)
        {
        return _d;
        }
    u32 count(void)
        {
        return _d.length();
        }

    void p8(u32 b)
        {
        _d.appendByte((u8)(b & (u32)$FF));
        }

    // Unsigned LEB128 (u64-capable: body sizes, counts, indices, offsets).
    void pU(u64 v)
        {
        while (true)
            {
            u8 b = (u8)(v & (u64)$7F);
            v = v >> (u64)7;
            if (v != (u64)0)
                b = b | (u8)$80;
            _d.appendByte(b);
            if (v == (u64)0)
                break;
            }
        }

    // Signed LEB128 over i64 (i32.const / i64.const / init exprs).
    void pS(i64 v)
        {
        bool more = true;
        while (more)
            {
            u8 b = (u8)((u64)v & (u64)$7F);
            v = v >> (i64)7; // arithmetic shift
            if ((v == (i64)0 && (b & (u8)$40) == (u8)0) || (v == (i64)-1 && (b & (u8)$40) != (u8)0))
                more = false;
            else
                b = b | (u8)$80;
            _d.appendByte(b);
            }
        }

    // Length-prefixed name (the String's bytes are already UTF-8).
    void pName(String* s)
        {
        pU((u64)s.byteLength());
        if (s.byteLength() > (u32)0)
            _d.appendBytes(s.cString(), s.byteLength());
        }

    void appendBuf(WasmBuf* p)
        {
        _d.append(p.buf());
        }

    // id byte + payload size + payload.
    void section(u32 id, WasmBuf* p)
        {
        p8(id);
        pU((u64)p.count());
        _d.append(p.buf());
        }
    }

    // ── Model built from the WAT text ──────────────────────────────────────────
    class WasmSig
    {
    Array* _params;  // String@
    Array* _results; // String@

    void init(void)
        {
        _params = new Array();
        _results = new Array();
        }

    // Structural dedupe key: "(p1,p2)->(r1)".
    String* key(void)
        {
        String* s = String.withCString("(");
        for (u32 i = (u32)0; i < _params.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                s.appendCString(",");
            s.append((String*)_params.get(i));
            }
        s.appendCString(")->(");
        for (u32 i = (u32)0; i < _results.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                s.appendCString(",");
            s.append((String*)_results.get(i));
            }
        s.appendCString(")");
        return s;
        }
    }

    class WasmFn
    {
    String* _name;     // 0 for the anonymous export fn
    String* _exportAs; // non-0 when (export "x") inline
    WasmSig* _sig;
    Array* _paramNames; // String@
    Array* _localNames; // String@, after params
    Array* _localTypes; // String@
    Array* _bodyLines;  // String@
    bool _isImport;
    String* _importModule; // imports: the module string (#package)

    void init(void)
        {
        _sig = new WasmSig();
        _paramNames = new Array();
        _localNames = new Array();
        _localTypes = new Array();
        _bodyLines = new Array();
        _isImport = false;
        }
    }

    class WasmGlobal
    {
    bool _mut;
    i64 _init;
    String* _exportAs; // "" when not exported

    void init(void)
        {
        _mut = false;
        _init = (i64)0;
        _exportAs = String.withCString("");
        }
    }

    class WasmDataSeg
    {
    i64 _addr;
    String* _addrGlobal; // 0, or the $global the offset reads (W2)
    Data* _bytes;

    void init(void)
        {
        _addr = (i64)0;
        }
    }

    // ── The writer ─────────────────────────────────────────────────────────────
    class WasmWriter
    {
    String* _err;

    Map* _ops; // name -> Number (byte | imm<<8 | extra<<16)

    Array* _imports;     // WasmFn@
    Array* _funcs;       // WasmFn@
    Array* _datas;       // WasmDataSeg@
    Array* _globals;     // WasmGlobal@
    Array* _globalNames; // String@
    // Non-function imports (W2), in FILE order: kind (1 table / 2 memory /
    // 3 global / 0 a function row), module, name, mut. A function row keeps
    // the section interleaving without duplicating the WasmFn.
    Array* _impKinds;            // Number@
    Array* _impModules;          // String@
    Array* _impNames;            // String@
    Array* _impMuts;             // Number@ 0/1
    Array* _importedGlobalNames; // String@ ($ids, index space before defined)
    bool _memImported;
    bool _tableImported;
    bool _tableExported;
    String* _elemBaseGlobal; // 0, or the $global the elem offset reads
    u32 _memPages;
    bool _memExported;
    u32 _tableSize;
    i64 _elemBase;
    Array* _elemFns;        // String@
    Array* _namedTypeNames; // String@
    Array* _namedTypeSigs;  // WasmSig@, parallel

    Map* _fnIndex;        // $name -> Number
    Map* _globalIndex;    // $name -> Number
    Array* _types;        // WasmSig@, deduped, emission order
    Map* _typeIndex;      // sig key -> Number
    Map* _namedTypeIndex; // $name -> Number

    WasmFn* _cur;  // function being parsed, 0 at module level
    i32 _curDepth; // paren depth inside _cur

    bool _vtOk; // valType scratch flag

    // Interned keyword strings (one alloc each, not one per line).
    String* _kEmpty;
    String* _kDollar;
    String* _kQuote;
    String* _kClose;
    String* _kSemiSemi;
    String* _kPData;
    String* _kPModule;
    String* _kPImport;
    String* _kPType;
    String* _kPTable;
    String* _kPElem;
    String* _kPMemory;
    String* _kPGlobal;
    String* _kPFunc;
    String* _kPLocal;
    String* _kPMut;
    String* _kExportMemory;
    String* _kExportTable;
    String* _kGlobalGet;
    String* _kTableName;
    String* _kFunc;
    String* _kParam;
    String* _kResult;
    String* _kExport;
    String* _kI32Const;
    String* _kI32;
    String* _kI64;
    String* _kF32;
    String* _kF64;
    String* _kEnv;
    String* _kMemoryName;
    String* _kNameName;
    String* _kBlock;
    String* _kLoop;
    String* _kIf;
    String* _kElse;
    String* _kEnd;
    String* _kCallIndirect;
    String* _kRetCallIndirect;
    String* _kMemSize;
    String* _kMemGrow;
    String* _kMemCopy;
    String* _kMemFill;
    String* _kOffsetEq;
    String* _kQuestion;

    void init(void)
        {
        _err = (String*)0;
        _kEmpty = String.withCString("");
        _kDollar = String.withCString("$");
        _kQuote = String.withCString("\"");
        _kClose = String.withCString(")");
        _kSemiSemi = String.withCString(";;");
        _kPData = String.withCString("(data");
        _kPModule = String.withCString("(module");
        _kPImport = String.withCString("(import ");
        _kPType = String.withCString("(type ");
        _kPTable = String.withCString("(table");
        _kPElem = String.withCString("(elem");
        _kPMemory = String.withCString("(memory");
        _kPGlobal = String.withCString("(global");
        _kPFunc = String.withCString("(func");
        _kPLocal = String.withCString("(local ");
        _kPMut = String.withCString("(mut ");
        _kExportMemory = String.withCString("(export \"memory\")");
        _kExportTable = String.withCString("(export \"__indirect_function_table\")");
        _kGlobalGet = String.withCString("global.get");
        _kTableName = String.withCString("__indirect_function_table");
        _kFunc = String.withCString("func");
        _kParam = String.withCString("param");
        _kResult = String.withCString("result");
        _kExport = String.withCString("export");
        _kI32Const = String.withCString("i32.const");
        _kI32 = String.withCString("i32");
        _kI64 = String.withCString("i64");
        _kF32 = String.withCString("f32");
        _kF64 = String.withCString("f64");
        _kEnv = String.withCString("env");
        _kMemoryName = String.withCString("memory");
        _kNameName = String.withCString("name");
        _kBlock = String.withCString("block");
        _kLoop = String.withCString("loop");
        _kIf = String.withCString("if");
        _kElse = String.withCString("else");
        _kEnd = String.withCString("end");
        _kCallIndirect = String.withCString("call_indirect");
        _kRetCallIndirect = String.withCString("return_call_indirect");
        _kMemSize = String.withCString("memory.size");
        _kMemGrow = String.withCString("memory.grow");
        _kMemCopy = String.withCString("memory.copy");
        _kMemFill = String.withCString("memory.fill");
        _kOffsetEq = String.withCString("offset=");
        _kQuestion = String.withCString("?");
        _ops = new Map();
        buildOps();
        }

    String* why(void)
        {
        return _err;
        }

    // Error-out helper — first message wins, as the original's NSError does.
    bool fail(String* m)
        {
        if (_err == (String*)0)
            _err = m;
        return false;
        }

    // ── Small parsing helpers ────────────────────────────────────────────
    static bool isHexDigit(u8 c)
        {
        return (c >= (u8)'0' && c <= (u8)'9') || (c >= (u8)'a' && c <= (u8)'f') || (c >= (u8)'A' && c <= (u8)'F');
        }

    static u32 hexVal(u8 c)
        {
        if (c >= (u8)'0' && c <= (u8)'9')
            return (u32)(c - (u8)'0');
        if (c >= (u8)'a' && c <= (u8)'f')
            return (u32)(c - (u8)'a') + (u32)10;
        return (u32)(c - (u8)'A') + (u32)10;
        }

    // Decimal integer (NSString intValue / longLongValue: optional
    // whitespace, sign, decimal digits, stop at the first non-digit).
    static i64 decOf(String* t)
        {
        if (t == (String*)0)
            return (i64)0;
        u32 i = (u32)0;
        u32 n = t.byteLength();
        while (i < n && (t.byteAt(i) == (u8)' ' || t.byteAt(i) == (u8)9))
            i = i + (u32)1;
        bool neg = false;
        if (i < n && t.byteAt(i) == (u8)'-')
            {
            neg = true;
            i = i + (u32)1;
            }
        else if (i < n && t.byteAt(i) == (u8)'+')
            i = i + (u32)1;
        i64 v = (i64)0;
        while (i < n && t.byteAt(i) >= (u8)'0' && t.byteAt(i) <= (u8)'9')
            {
            v = v * (i64)10 + (i64)(t.byteAt(i) - (u8)'0');
            i = i + (u32)1;
            }
        if (neg)
            return (i64)0 - v;
        return v;
        }

    // strtoll(str, NULL, 0): sign, then 0x/0X hex, leading 0 octal, else
    // decimal. i64-wide — i64.const literals can exceed 32 bits.
    static i64 parseI64(String* t)
        {
        if (t == (String*)0)
            return (i64)0;
        u32 i = (u32)0;
        u32 n = t.byteLength();
        while (i < n && (t.byteAt(i) == (u8)' ' || t.byteAt(i) == (u8)9))
            i = i + (u32)1;
        bool neg = false;
        if (i < n && t.byteAt(i) == (u8)'-')
            {
            neg = true;
            i = i + (u32)1;
            }
        else if (i < n && t.byteAt(i) == (u8)'+')
            i = i + (u32)1;
        u64 base = (u64)10;
        if (i + (u32)1 < n && t.byteAt(i) == (u8)'0' && (t.byteAt(i + (u32)1) == (u8)'x' || t.byteAt(i + (u32)1) == (u8)'X'))
            {
            base = (u64)16;
            i = i + (u32)2;
            }
        else if (i < n && t.byteAt(i) == (u8)'0')
            {
            base = (u64)8;
            }
        u64 v = (u64)0;
        while (i < n)
            {
            u8 c = t.byteAt(i);
            u32 d;
            if (c >= (u8)'0' && c <= (u8)'9')
                d = (u32)(c - (u8)'0');
            else if (c >= (u8)'a' && c <= (u8)'f')
                d = (u32)(c - (u8)'a') + (u32)10;
            else if (c >= (u8)'A' && c <= (u8)'F')
                d = (u32)(c - (u8)'A') + (u32)10;
            else
                break;
            if ((u64)d >= base)
                break;
            v = v * base + (u64)d;
            i = i + (u32)1;
            }
        if (neg)
            return (i64)0 - (i64)v;
        return (i64)v;
        }

    // ── Hex-float (C `%a`) to double bits — exact for the dialect's ≤14
    // hex digits, with round-to-nearest-even wherever a shift could drop
    // bits, matching strtod. ─────────────────────────────────────────────
    static u64 hexFloatBits(String* t)
        {
        u64 sign = (u64)0;
        u32 i = (u32)0;
        u32 n = t.byteLength();
        if (i < n && t.byteAt(i) == (u8)'-')
            {
            sign = (u64)1 << (u64)63;
            i = i + (u32)1;
            }
        else if (i < n && t.byteAt(i) == (u8)'+')
            i = i + (u32)1;
        if (i + (u32)1 < n && t.byteAt(i) == (u8)'0' && (t.byteAt(i + (u32)1) == (u8)'x' || t.byteAt(i + (u32)1) == (u8)'X'))
            i = i + (u32)2;
        u64 mant = (u64)0;
        i32 e = (i32)0;
        while (i < n && WasmWriter.isHexDigit(t.byteAt(i)))
            {
            mant = (mant << (u64)4) | (u64)WasmWriter.hexVal(t.byteAt(i));
            i = i + (u32)1;
            }
        if (i < n && t.byteAt(i) == (u8)'.')
            {
            i = i + (u32)1;
            while (i < n && WasmWriter.isHexDigit(t.byteAt(i)))
                {
                mant = (mant << (u64)4) | (u64)WasmWriter.hexVal(t.byteAt(i));
                e = e - (i32)4;
                i = i + (u32)1;
                }
            }
        if (i < n && (t.byteAt(i) == (u8)'p' || t.byteAt(i) == (u8)'P'))
            {
            i = i + (u32)1;
            bool neg = false;
            if (i < n && t.byteAt(i) == (u8)'-')
                {
                neg = true;
                i = i + (u32)1;
                }
            else if (i < n && t.byteAt(i) == (u8)'+')
                i = i + (u32)1;
            i32 pe = (i32)0;
            while (i < n && t.byteAt(i) >= (u8)'0' && t.byteAt(i) <= (u8)'9')
                {
                pe = pe * (i32)10 + (i32)(t.byteAt(i) - (u8)'0');
                i = i + (u32)1;
                }
            if (neg)
                e = e - pe;
            else
                e = e + pe;
            }
        if (mant == (u64)0)
            return sign; // ±0
        u32 b = (u32)63;
        while (((mant >> (u64)b) & (u64)1) == (u64)0)
            b = b - (u32)1;
        i32 E = e + (i32)b;
        u64 keep;
        if (b > (u32)52)
            {
            u32 sh = b - (u32)52;
            u64 rest = mant & (((u64)1 << (u64)sh) - (u64)1);
            u64 half = (u64)1 << (u64)(sh - (u32)1);
            keep = mant >> (u64)sh;
            if (rest > half || (rest == half && (keep & (u64)1) != (u64)0))
                {
                keep = keep + (u64)1;
                if (keep == ((u64)1 << (u64)53))
                    {
                    keep = keep >> (u64)1;
                    E = E + (i32)1;
                    }
                }
            }
        else
            {
            keep = mant << (u64)((u32)52 - b);
            }
        if (E > (i32)1023)
            return sign | ((u64)$7FF << (u64)52); // inf
        if (E >= (i32)-1022)
            return sign | ((u64)(E + (i32)1023) << (u64)52) | (keep & (u64)$FFFFFFFFFFFFF);
        // Subnormal double: shift the 53-bit significand down, RNE.
        u32 sh2 = (u32)((i32)-1022 - E);
        if (sh2 > (u32)63)
            return sign;
        u64 rest2 = keep & (((u64)1 << (u64)sh2) - (u64)1);
        u64 half2 = (u64)1 << (u64)(sh2 - (u32)1);
        u64 keep2 = keep >> (u64)sh2;
        if (rest2 > half2 || (rest2 == half2 && (keep2 & (u64)1) != (u64)0))
            keep2 = keep2 + (u64)1;
        return sign | keep2;
        }

    // (float) of the double the 64 bits spell, as float bits — round to
    // nearest, ties to even (matches strtof over the same text, which is
    // exact for the dialect: f32.const literals ARE float values).
    static u32 dblToFltBits(u64 d)
        {
        u32 sign = (u32)(d >> (u64)63) << (u32)31;
        u32 ef = (u32)((d >> (u64)52) & (u64)$7FF);
        u64 m = d & (u64)$FFFFFFFFFFFFF;
        if (ef == (u32)$7FF)
            {
            if (m == (u64)0)
                return sign | (u32)$7F800000;
            u32 fm = (u32)(m >> (u64)29) & (u32)$3FFFFF;
            return sign | (u32)$7FC00000 | fm;
            }
        if (ef == (u32)0)
            return sign; // double subnormal is far below float range
        i32 ue = (i32)ef - (i32)1023;
        if (ue >= (i32)128)
            return sign | (u32)$7F800000;
        if (ue >= (i32)-126)
            {
            u64 keep = m >> (u64)29;
            u64 rest = m & (u64)$1FFFFFFF;
            u64 half = (u64)$10000000;
            if (rest > half || (rest == half && (keep & (u64)1) != (u64)0))
                keep = keep + (u64)1;
            if (keep == (u64)$800000)
                {
                keep = (u64)0;
                ue = ue + (i32)1;
                }
            if (ue >= (i32)128)
                return sign | (u32)$7F800000;
            return sign | ((u32)(ue + (i32)127) << (u32)23) | (u32)keep;
            }
        // Float subnormal (or zero): significand with hidden bit, shifted.
        u64 sig = ((u64)1 << (u64)52) | m;
        u32 sh = (u32)29 + (u32)((i32)-126 - ue);
        if (sh > (u32)63)
            return sign;
        u64 keep2 = sig >> (u64)sh;
        u64 rest2 = sig & (((u64)1 << (u64)sh) - (u64)1);
        u64 half2 = (u64)1 << (u64)(sh - (u32)1);
        if (rest2 > half2 || (rest2 == half2 && (keep2 & (u64)1) != (u64)0))
            keep2 = keep2 + (u64)1;
        return sign | (u32)keep2;
        }

    // ── Value types ──────────────────────────────────────────────────────
    u32 valType(String* t)
        {
        if (t.equals(_kI32))
            return (u32)$7F;
        if (t.equals(_kI64))
            return (u32)$7E;
        if (t.equals(_kF32))
            return (u32)$7D;
        if (t.equals(_kF64))
            return (u32)$7C;
        if (t.equals(String.withCString("v128")))
            return (u32)$7B;
        _vtOk = false;
        return (u32)$7F;
        }

    // ── Lexing helpers ───────────────────────────────────────────────────
    // Split on parens / space / tab; a quoted string is one token, kept
    // WITH its quotes.
    static Array* tokensOf(String* line)
        {
        Array* toks = new Array();
        String* curTok = String.withCString("");
        bool inStr = false;
        u32 n = line.byteLength();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            u8 c = line.byteAt(i);
            if (inStr)
                {
                curTok.appendByte(c);
                if (c == (u8)'"')
                    {
                    toks.add((Object*)String.withString(curTok));
                    curTok.clear();
                    inStr = false;
                    }
                continue;
                }
            if (c == (u8)'"')
                {
                if (curTok.byteLength() > (u32)0)
                    {
                    toks.add((Object*)String.withString(curTok));
                    curTok.clear();
                    }
                curTok.appendByte((u8)'"');
                inStr = true;
                continue;
                }
            if (c == (u8)'(' || c == (u8)')' || c == (u8)' ' || c == (u8)9)
                {
                if (curTok.byteLength() > (u32)0)
                    {
                    toks.add((Object*)String.withString(curTok));
                    curTok.clear();
                    }
                continue;
                }
            curTok.appendByte(c);
            }
        if (curTok.byteLength() > (u32)0)
            toks.add((Object*)String.withString(curTok));
        return toks;
        }

    // `\XX` hex escapes (two lowercase hex digits from watStringLit),
    // everything else verbatim.
    static Data* bytesOfDataLiteral(String* lit)
        {
        Data* d = Data.withCapacity((u32)0);
        u32 n = lit.byteLength();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            u8 c = lit.byteAt(i);
            if (c == (u8)'\\' && i + (u32)1 < n)
                {
                u32 hex = (u32)0;
                u8 c1 = lit.byteAt(i + (u32)1);
                if (WasmWriter.isHexDigit(c1))
                    {
                    hex = WasmWriter.hexVal(c1);
                    if (i + (u32)2 < n && WasmWriter.isHexDigit(lit.byteAt(i + (u32)2)))
                        hex = hex * (u32)16 + WasmWriter.hexVal(lit.byteAt(i + (u32)2));
                    }
                d.appendByte((u8)hex);
                i = i + (u32)2;
                }
            else
                {
                d.appendByte(c);
                }
            }
        return d;
        }

    // Quoted token -> its contents (strip first and last char).
    static String* unquote(String* t)
        {
        if (t.byteLength() < (u32)2)
            return String.withCString("");
        return t.substringBytes((u32)1, t.byteLength() - (u32)2);
        }

    // ── Opcode table ─────────────────────────────────────────────────────
    void op(string name, u32 b, u32 imm, u32 extra)
        {
        _ops.set((Hashable*)String.withCString(name),
                 (Object*)Number.withU32(b | (imm << (u32)8) | (extra << (u32)16)));
        }

    void buildOps(void)
        {
        op("unreachable", (u32)$00, (u32)WIMM_NONE, (u32)0);
        op("nop", (u32)$01, (u32)WIMM_NONE, (u32)0);
        op("return", (u32)$0F, (u32)WIMM_NONE, (u32)0);
        op("drop", (u32)$1A, (u32)WIMM_NONE, (u32)0);
        op("select", (u32)$1B, (u32)WIMM_NONE, (u32)0);
        op("br", (u32)$0C, (u32)WIMM_LABEL, (u32)0);
        op("br_if", (u32)$0D, (u32)WIMM_LABEL, (u32)0);
        op("br_table", (u32)$0E, (u32)WIMM_BRTABLE, (u32)0);
        op("call", (u32)$10, (u32)WIMM_CALL, (u32)0);
        op("return_call", (u32)$12, (u32)WIMM_CALL, (u32)0);
        op("local.get", (u32)$20, (u32)WIMM_LOCAL, (u32)0);
        op("local.set", (u32)$21, (u32)WIMM_LOCAL, (u32)0);
        op("local.tee", (u32)$22, (u32)WIMM_LOCAL, (u32)0);
        op("global.get", (u32)$23, (u32)WIMM_GLOBAL, (u32)0);
        op("global.set", (u32)$24, (u32)WIMM_GLOBAL, (u32)0);
        op("i32.const", (u32)$41, (u32)WIMM_I32, (u32)0);
        op("i64.const", (u32)$42, (u32)WIMM_I64, (u32)0);
        op("f32.const", (u32)$43, (u32)WIMM_F32, (u32)0);
        op("f64.const", (u32)$44, (u32)WIMM_F64, (u32)0);
        buildOpsMem();
        buildOpsI32();
        buildOpsI64();
        buildOpsFp();
        buildOpsConv();
        buildOpsSimd();
        }

    void buildOpsMem(void)
        {
        // loads/stores (align+offset immediates, natural align log2)
        op("i32.load", (u32)$28, (u32)WIMM_MEMPAIR, (u32)2);
        op("i64.load", (u32)$29, (u32)WIMM_MEMPAIR, (u32)3);
        op("f32.load", (u32)$2A, (u32)WIMM_MEMPAIR, (u32)2);
        op("f64.load", (u32)$2B, (u32)WIMM_MEMPAIR, (u32)3);
        op("i32.load8_s", (u32)$2C, (u32)WIMM_MEMPAIR, (u32)0);
        op("i32.load8_u", (u32)$2D, (u32)WIMM_MEMPAIR, (u32)0);
        op("i32.load16_s", (u32)$2E, (u32)WIMM_MEMPAIR, (u32)1);
        op("i32.load16_u", (u32)$2F, (u32)WIMM_MEMPAIR, (u32)1);
        op("i64.load8_s", (u32)$30, (u32)WIMM_MEMPAIR, (u32)0);
        op("i64.load8_u", (u32)$31, (u32)WIMM_MEMPAIR, (u32)0);
        op("i64.load16_s", (u32)$32, (u32)WIMM_MEMPAIR, (u32)1);
        op("i64.load16_u", (u32)$33, (u32)WIMM_MEMPAIR, (u32)1);
        op("i64.load32_s", (u32)$34, (u32)WIMM_MEMPAIR, (u32)2);
        op("i64.load32_u", (u32)$35, (u32)WIMM_MEMPAIR, (u32)2);
        op("i32.store", (u32)$36, (u32)WIMM_MEMPAIR, (u32)2);
        op("i64.store", (u32)$37, (u32)WIMM_MEMPAIR, (u32)3);
        op("f32.store", (u32)$38, (u32)WIMM_MEMPAIR, (u32)2);
        op("f64.store", (u32)$39, (u32)WIMM_MEMPAIR, (u32)3);
        op("i32.store8", (u32)$3A, (u32)WIMM_MEMPAIR, (u32)0);
        op("i32.store16", (u32)$3B, (u32)WIMM_MEMPAIR, (u32)1);
        op("i64.store8", (u32)$3C, (u32)WIMM_MEMPAIR, (u32)0);
        op("i64.store16", (u32)$3D, (u32)WIMM_MEMPAIR, (u32)1);
        op("i64.store32", (u32)$3E, (u32)WIMM_MEMPAIR, (u32)2);
        }

    void buildOpsI32(void)
        {
        op("i32.eqz", (u32)$45, (u32)WIMM_NONE, (u32)0);
        op("i32.eq", (u32)$46, (u32)WIMM_NONE, (u32)0);
        op("i32.ne", (u32)$47, (u32)WIMM_NONE, (u32)0);
        op("i32.lt_s", (u32)$48, (u32)WIMM_NONE, (u32)0);
        op("i32.lt_u", (u32)$49, (u32)WIMM_NONE, (u32)0);
        op("i32.gt_s", (u32)$4A, (u32)WIMM_NONE, (u32)0);
        op("i32.gt_u", (u32)$4B, (u32)WIMM_NONE, (u32)0);
        op("i32.le_s", (u32)$4C, (u32)WIMM_NONE, (u32)0);
        op("i32.le_u", (u32)$4D, (u32)WIMM_NONE, (u32)0);
        op("i32.ge_s", (u32)$4E, (u32)WIMM_NONE, (u32)0);
        op("i32.ge_u", (u32)$4F, (u32)WIMM_NONE, (u32)0);
        op("i32.add", (u32)$6A, (u32)WIMM_NONE, (u32)0);
        op("i32.sub", (u32)$6B, (u32)WIMM_NONE, (u32)0);
        op("i32.mul", (u32)$6C, (u32)WIMM_NONE, (u32)0);
        op("i32.div_s", (u32)$6D, (u32)WIMM_NONE, (u32)0);
        op("i32.div_u", (u32)$6E, (u32)WIMM_NONE, (u32)0);
        op("i32.rem_s", (u32)$6F, (u32)WIMM_NONE, (u32)0);
        op("i32.rem_u", (u32)$70, (u32)WIMM_NONE, (u32)0);
        op("i32.and", (u32)$71, (u32)WIMM_NONE, (u32)0);
        op("i32.or", (u32)$72, (u32)WIMM_NONE, (u32)0);
        op("i32.xor", (u32)$73, (u32)WIMM_NONE, (u32)0);
        op("i32.shl", (u32)$74, (u32)WIMM_NONE, (u32)0);
        op("i32.shr_s", (u32)$75, (u32)WIMM_NONE, (u32)0);
        op("i32.shr_u", (u32)$76, (u32)WIMM_NONE, (u32)0);
        op("i32.rotl", (u32)$77, (u32)WIMM_NONE, (u32)0);
        op("i32.rotr", (u32)$78, (u32)WIMM_NONE, (u32)0);
        }

    void buildOpsI64(void)
        {
        op("i64.eqz", (u32)$50, (u32)WIMM_NONE, (u32)0);
        op("i64.eq", (u32)$51, (u32)WIMM_NONE, (u32)0);
        op("i64.ne", (u32)$52, (u32)WIMM_NONE, (u32)0);
        op("i64.lt_s", (u32)$53, (u32)WIMM_NONE, (u32)0);
        op("i64.lt_u", (u32)$54, (u32)WIMM_NONE, (u32)0);
        op("i64.gt_s", (u32)$55, (u32)WIMM_NONE, (u32)0);
        op("i64.gt_u", (u32)$56, (u32)WIMM_NONE, (u32)0);
        op("i64.le_s", (u32)$57, (u32)WIMM_NONE, (u32)0);
        op("i64.le_u", (u32)$58, (u32)WIMM_NONE, (u32)0);
        op("i64.ge_s", (u32)$59, (u32)WIMM_NONE, (u32)0);
        op("i64.ge_u", (u32)$5A, (u32)WIMM_NONE, (u32)0);
        op("i64.add", (u32)$7C, (u32)WIMM_NONE, (u32)0);
        op("i64.sub", (u32)$7D, (u32)WIMM_NONE, (u32)0);
        op("i64.mul", (u32)$7E, (u32)WIMM_NONE, (u32)0);
        op("i64.div_s", (u32)$7F, (u32)WIMM_NONE, (u32)0);
        op("i64.div_u", (u32)$80, (u32)WIMM_NONE, (u32)0);
        op("i64.rem_s", (u32)$81, (u32)WIMM_NONE, (u32)0);
        op("i64.rem_u", (u32)$82, (u32)WIMM_NONE, (u32)0);
        op("i64.and", (u32)$83, (u32)WIMM_NONE, (u32)0);
        op("i64.or", (u32)$84, (u32)WIMM_NONE, (u32)0);
        op("i64.xor", (u32)$85, (u32)WIMM_NONE, (u32)0);
        op("i64.shl", (u32)$86, (u32)WIMM_NONE, (u32)0);
        op("i64.shr_s", (u32)$87, (u32)WIMM_NONE, (u32)0);
        op("i64.shr_u", (u32)$88, (u32)WIMM_NONE, (u32)0);
        op("i64.rotl", (u32)$89, (u32)WIMM_NONE, (u32)0);
        op("i64.rotr", (u32)$8A, (u32)WIMM_NONE, (u32)0);
        }

    void buildOpsFp(void)
        {
        op("f32.eq", (u32)$5B, (u32)WIMM_NONE, (u32)0);
        op("f32.ne", (u32)$5C, (u32)WIMM_NONE, (u32)0);
        op("f32.lt", (u32)$5D, (u32)WIMM_NONE, (u32)0);
        op("f32.gt", (u32)$5E, (u32)WIMM_NONE, (u32)0);
        op("f32.le", (u32)$5F, (u32)WIMM_NONE, (u32)0);
        op("f32.ge", (u32)$60, (u32)WIMM_NONE, (u32)0);
        op("f64.eq", (u32)$61, (u32)WIMM_NONE, (u32)0);
        op("f64.ne", (u32)$62, (u32)WIMM_NONE, (u32)0);
        op("f64.lt", (u32)$63, (u32)WIMM_NONE, (u32)0);
        op("f64.gt", (u32)$64, (u32)WIMM_NONE, (u32)0);
        op("f64.le", (u32)$65, (u32)WIMM_NONE, (u32)0);
        op("f64.ge", (u32)$66, (u32)WIMM_NONE, (u32)0);
        op("f32.neg", (u32)$8C, (u32)WIMM_NONE, (u32)0);
        op("f32.sqrt", (u32)$91, (u32)WIMM_NONE, (u32)0);
        op("f32.add", (u32)$92, (u32)WIMM_NONE, (u32)0);
        op("f32.sub", (u32)$93, (u32)WIMM_NONE, (u32)0);
        op("f32.mul", (u32)$94, (u32)WIMM_NONE, (u32)0);
        op("f32.div", (u32)$95, (u32)WIMM_NONE, (u32)0);
        op("f64.neg", (u32)$9A, (u32)WIMM_NONE, (u32)0);
        op("f64.sqrt", (u32)$9F, (u32)WIMM_NONE, (u32)0);
        op("f64.add", (u32)$A0, (u32)WIMM_NONE, (u32)0);
        op("f64.sub", (u32)$A1, (u32)WIMM_NONE, (u32)0);
        op("f64.mul", (u32)$A2, (u32)WIMM_NONE, (u32)0);
        op("f64.div", (u32)$A3, (u32)WIMM_NONE, (u32)0);
        }

    void buildOpsConv(void)
        {
        op("i32.wrap_i64", (u32)$A7, (u32)WIMM_NONE, (u32)0);
        op("i64.extend_i32_s", (u32)$AC, (u32)WIMM_NONE, (u32)0);
        op("i64.extend_i32_u", (u32)$AD, (u32)WIMM_NONE, (u32)0);
        op("f32.convert_i32_s", (u32)$B2, (u32)WIMM_NONE, (u32)0);
        op("f32.convert_i32_u", (u32)$B3, (u32)WIMM_NONE, (u32)0);
        op("f32.convert_i64_s", (u32)$B4, (u32)WIMM_NONE, (u32)0);
        op("f32.convert_i64_u", (u32)$B5, (u32)WIMM_NONE, (u32)0);
        op("f32.demote_f64", (u32)$B6, (u32)WIMM_NONE, (u32)0);
        op("f64.convert_i32_s", (u32)$B7, (u32)WIMM_NONE, (u32)0);
        op("f64.convert_i32_u", (u32)$B8, (u32)WIMM_NONE, (u32)0);
        op("f64.convert_i64_s", (u32)$B9, (u32)WIMM_NONE, (u32)0);
        op("f64.convert_i64_u", (u32)$BA, (u32)WIMM_NONE, (u32)0);
        op("f64.promote_f32", (u32)$BB, (u32)WIMM_NONE, (u32)0);
        op("i32.reinterpret_f32", (u32)$BC, (u32)WIMM_NONE, (u32)0);
        op("i64.reinterpret_f64", (u32)$BD, (u32)WIMM_NONE, (u32)0);
        op("f32.reinterpret_i32", (u32)$BE, (u32)WIMM_NONE, (u32)0);
        op("f64.reinterpret_i64", (u32)$BF, (u32)WIMM_NONE, (u32)0);
        op("i32.extend8_s", (u32)$C0, (u32)WIMM_NONE, (u32)0);
        op("i32.extend16_s", (u32)$C1, (u32)WIMM_NONE, (u32)0);
        op("i64.extend8_s", (u32)$C2, (u32)WIMM_NONE, (u32)0);
        op("i64.extend16_s", (u32)$C3, (u32)WIMM_NONE, (u32)0);
        op("i64.extend32_s", (u32)$C4, (u32)WIMM_NONE, (u32)0);
        // 0xFC-prefixed (extra = the sub-opcode)
        op("i32.trunc_sat_f32_s", (u32)$FC, (u32)WIMM_NONE, (u32)0);
        op("i32.trunc_sat_f32_u", (u32)$FC, (u32)WIMM_NONE, (u32)1);
        op("i32.trunc_sat_f64_s", (u32)$FC, (u32)WIMM_NONE, (u32)2);
        op("i32.trunc_sat_f64_u", (u32)$FC, (u32)WIMM_NONE, (u32)3);
        op("i64.trunc_sat_f32_s", (u32)$FC, (u32)WIMM_NONE, (u32)4);
        op("i64.trunc_sat_f32_u", (u32)$FC, (u32)WIMM_NONE, (u32)5);
        op("i64.trunc_sat_f64_s", (u32)$FC, (u32)WIMM_NONE, (u32)6);
        op("i64.trunc_sat_f64_u", (u32)$FC, (u32)WIMM_NONE, (u32)7);
        op("memory.copy", (u32)$FC, (u32)WIMM_NONE, (u32)10);
        op("memory.fill", (u32)$FC, (u32)WIMM_NONE, (u32)11);
        }

    // 0xFD-prefixed SIMD (extra = the LEB sub-opcode). The two memory ops
    // carry a memarg — natural align for v128 is 16 bytes (log2 4), which
    // the WIMM_MEMPAIR arm special-cases on the 0xFD prefix.
    void buildOpsSimd(void)
        {
        op("v128.load", (u32)$FD, (u32)WIMM_MEMPAIR, (u32)0);
        op("v128.store", (u32)$FD, (u32)WIMM_MEMPAIR, (u32)11);
        op("i8x16.shuffle", (u32)$FD, (u32)WIMM_LANES16, (u32)13);
        op("i8x16.splat", (u32)$FD, (u32)WIMM_NONE, (u32)15);
        op("i16x8.splat", (u32)$FD, (u32)WIMM_NONE, (u32)16);
        op("i32x4.splat", (u32)$FD, (u32)WIMM_NONE, (u32)17);
        op("f32x4.splat", (u32)$FD, (u32)WIMM_NONE, (u32)19);
        op("i32x4.extract_lane", (u32)$FD, (u32)WIMM_LANE, (u32)27);
        op("i8x16.eq", (u32)$FD, (u32)WIMM_NONE, (u32)35);
        op("i8x16.ne", (u32)$FD, (u32)WIMM_NONE, (u32)36);
        op("i8x16.lt_s", (u32)$FD, (u32)WIMM_NONE, (u32)37);
        op("i8x16.lt_u", (u32)$FD, (u32)WIMM_NONE, (u32)38);
        op("i8x16.gt_s", (u32)$FD, (u32)WIMM_NONE, (u32)39);
        op("i8x16.gt_u", (u32)$FD, (u32)WIMM_NONE, (u32)40);
        op("i8x16.le_s", (u32)$FD, (u32)WIMM_NONE, (u32)41);
        op("i8x16.le_u", (u32)$FD, (u32)WIMM_NONE, (u32)42);
        op("i8x16.ge_s", (u32)$FD, (u32)WIMM_NONE, (u32)43);
        op("i8x16.ge_u", (u32)$FD, (u32)WIMM_NONE, (u32)44);
        op("i16x8.eq", (u32)$FD, (u32)WIMM_NONE, (u32)45);
        op("i16x8.ne", (u32)$FD, (u32)WIMM_NONE, (u32)46);
        op("i16x8.lt_s", (u32)$FD, (u32)WIMM_NONE, (u32)47);
        op("i16x8.lt_u", (u32)$FD, (u32)WIMM_NONE, (u32)48);
        op("i16x8.gt_s", (u32)$FD, (u32)WIMM_NONE, (u32)49);
        op("i16x8.gt_u", (u32)$FD, (u32)WIMM_NONE, (u32)50);
        op("i16x8.le_s", (u32)$FD, (u32)WIMM_NONE, (u32)51);
        op("i16x8.le_u", (u32)$FD, (u32)WIMM_NONE, (u32)52);
        op("i16x8.ge_s", (u32)$FD, (u32)WIMM_NONE, (u32)53);
        op("i16x8.ge_u", (u32)$FD, (u32)WIMM_NONE, (u32)54);
        op("i32x4.eq", (u32)$FD, (u32)WIMM_NONE, (u32)55);
        op("i32x4.ne", (u32)$FD, (u32)WIMM_NONE, (u32)56);
        op("i32x4.lt_s", (u32)$FD, (u32)WIMM_NONE, (u32)57);
        op("i32x4.lt_u", (u32)$FD, (u32)WIMM_NONE, (u32)58);
        op("i32x4.gt_s", (u32)$FD, (u32)WIMM_NONE, (u32)59);
        op("i32x4.gt_u", (u32)$FD, (u32)WIMM_NONE, (u32)60);
        op("i32x4.le_s", (u32)$FD, (u32)WIMM_NONE, (u32)61);
        op("i32x4.le_u", (u32)$FD, (u32)WIMM_NONE, (u32)62);
        op("i32x4.ge_s", (u32)$FD, (u32)WIMM_NONE, (u32)63);
        op("i32x4.ge_u", (u32)$FD, (u32)WIMM_NONE, (u32)64);
        op("v128.and", (u32)$FD, (u32)WIMM_NONE, (u32)78);
        op("v128.or", (u32)$FD, (u32)WIMM_NONE, (u32)80);
        op("v128.xor", (u32)$FD, (u32)WIMM_NONE, (u32)81);
        op("i8x16.add", (u32)$FD, (u32)WIMM_NONE, (u32)110);
        op("i8x16.sub", (u32)$FD, (u32)WIMM_NONE, (u32)113);
        op("i8x16.min_s", (u32)$FD, (u32)WIMM_NONE, (u32)118);
        op("i8x16.min_u", (u32)$FD, (u32)WIMM_NONE, (u32)119);
        op("i8x16.max_s", (u32)$FD, (u32)WIMM_NONE, (u32)120);
        op("i8x16.max_u", (u32)$FD, (u32)WIMM_NONE, (u32)121);
        op("i16x8.extadd_pairwise_i8x16_u", (u32)$FD, (u32)WIMM_NONE, (u32)125);
        op("i32x4.extadd_pairwise_i16x8_u", (u32)$FD, (u32)WIMM_NONE, (u32)127);
        op("i16x8.extend_low_i8x16_u", (u32)$FD, (u32)WIMM_NONE, (u32)137);
        op("i16x8.extend_high_i8x16_u", (u32)$FD, (u32)WIMM_NONE, (u32)138);
        op("i16x8.add", (u32)$FD, (u32)WIMM_NONE, (u32)142);
        op("i16x8.sub", (u32)$FD, (u32)WIMM_NONE, (u32)145);
        op("i16x8.mul", (u32)$FD, (u32)WIMM_NONE, (u32)149);
        op("i16x8.min_s", (u32)$FD, (u32)WIMM_NONE, (u32)150);
        op("i16x8.min_u", (u32)$FD, (u32)WIMM_NONE, (u32)151);
        op("i16x8.max_s", (u32)$FD, (u32)WIMM_NONE, (u32)152);
        op("i16x8.max_u", (u32)$FD, (u32)WIMM_NONE, (u32)153);
        op("i32x4.add", (u32)$FD, (u32)WIMM_NONE, (u32)174);
        op("i32x4.sub", (u32)$FD, (u32)WIMM_NONE, (u32)177);
        op("i32x4.mul", (u32)$FD, (u32)WIMM_NONE, (u32)181);
        op("i32x4.min_s", (u32)$FD, (u32)WIMM_NONE, (u32)182);
        op("i32x4.min_u", (u32)$FD, (u32)WIMM_NONE, (u32)183);
        op("i32x4.max_s", (u32)$FD, (u32)WIMM_NONE, (u32)184);
        op("i32x4.max_u", (u32)$FD, (u32)WIMM_NONE, (u32)185);
        op("f32x4.add", (u32)$FD, (u32)WIMM_NONE, (u32)228);
        op("f32x4.sub", (u32)$FD, (u32)WIMM_NONE, (u32)229);
        op("f32x4.mul", (u32)$FD, (u32)WIMM_NONE, (u32)230);
        op("f32x4.min", (u32)$FD, (u32)WIMM_NONE, (u32)232);
        op("f32x4.max", (u32)$FD, (u32)WIMM_NONE, (u32)233);
        }

    // ── Type dedupe ──────────────────────────────────────────────────────
    Number* typeFor(WasmSig* s)
        {
        String* k = s.key();
        Object* have = _typeIndex.get((Hashable*)k);
        if (have != (Object*)0)
            return (Number*)have;
        Number* idx = Number.withU32(_types.count());
        _types.add((Object*)s);
        _typeIndex.set((Hashable*)k, (Object*)idx);
        return idx;
        }

    // Label depth = distance from the top of the label stack.
    static i32 depthOf(Array* labels, String* want)
        {
        i32 n = (i32)labels.count();
        for (i32 i = n - (i32)1; i >= (i32)0; i = i - (i32)1)
            if (((String*)labels.get((u32)i)).equals(want))
                return n - (i32)1 - i;
        return (i32)-1;
        }

    // ── Parsing: one form per method ─────────────────────────────────────
    // Inside a function body until its closing `)`.
    bool parseBodyLine(String* line)
        {
        i32 opens = (i32)0;
        i32 closes = (i32)0;
        for (u32 i = (u32)0; i < line.byteLength(); i = i + (u32)1)
            {
            u8 ch = line.byteAt(i);
            if (ch == (u8)'(')
                opens = opens + (i32)1;
            else if (ch == (u8)')')
                closes = closes + (i32)1;
            }
        if (line.equals(_kClose) && _curDepth == (i32)1)
            {
            _funcs.add((Object*)_cur);
            _cur = (WasmFn*)0;
            return true;
            }
        _curDepth = _curDepth + opens - closes;
        if (line.hasPrefix(_kPLocal))
            {
            // (local $name ty) — possibly several per line.
            Array* toks = WasmWriter.tokensOf(line);
            for (u32 i = (u32)0; i + (u32)1 < toks.count(); i = i + (u32)1)
                {
                if (!((String*)toks.get(i)).hasPrefix(_kDollar))
                    continue;
                _cur._localNames.add(toks.get(i));
                _cur._localTypes.add(toks.get(i + (u32)1));
                }
            return true;
            }
        _cur._bodyLines.add((Object*)line);
        return true;
        }

    // (import "env" "name" (func $name (param T)* (result T)?))
    // (import "env" "memory" (memory N))              — W2
    // (import "env" "..." (table N funcref))          — W2
    // (import "env" "name" (global $g i32|(mut i32))) — W2
    bool parseImport(String* line)
        {
        Array* toks = WasmWriter.tokensOf(line);
        Array* strs = new Array();
        for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1)
            {
            String* t = (String*)toks.get(i);
            if (t.hasPrefix(_kQuote))
                strs.add((Object*)WasmWriter.unquote(t));
            }
        if (strs.count() < (u32)2)
            return fail(String.withCString("malformed import"));
        if (line.contains(_kPMemory))
            {
            _memImported = true;
            _impKinds.add((Object*)Number.withU32((u32)2));
            _impModules.add(strs.get((u32)0));
            _impNames.add(strs.get((u32)1));
            _impMuts.add((Object*)Number.withU32((u32)0));
            return true;
            }
        if (line.contains(_kPTable))
            {
            _tableImported = true;
            _impKinds.add((Object*)Number.withU32((u32)1));
            _impModules.add(strs.get((u32)0));
            _impNames.add(strs.get((u32)1));
            _impMuts.add((Object*)Number.withU32((u32)0));
            return true;
            }
        if (line.contains(_kPGlobal))
            {
            String* gname = (String*)0;
            for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1)
                {
                String* t = (String*)toks.get(i);
                if (t.hasPrefix(_kDollar))
                    {
                    gname = t;
                    break;
                    }
                }
            if (gname == (String*)0)
                return fail(String.withCString("global import without $name"));
            _impKinds.add((Object*)Number.withU32((u32)3));
            _impModules.add(strs.get((u32)0));
            _impNames.add(strs.get((u32)1));
            _impMuts.add((Object*)Number.withU32(line.contains(_kPMut) ? (u32)1 : (u32)0));
            _importedGlobalNames.add((Object*)gname);
            return true;
            }
        WasmFn* imp = new WasmFn();
        imp._isImport = true;
        imp._importModule = (String*)strs.get((u32)0); // "#package" namespace
        imp._exportAs = (String*)strs.get((u32)1);     // reuse: the import NAME
        for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1)
            {
            String* t = (String*)toks.get(i);
            if (t.hasPrefix(_kDollar) && imp._name == (String*)0)
                imp._name = t;
            if (t.equals(_kParam) && i + (u32)1 < toks.count())
                imp._sig._params.add(toks.get(i + (u32)1));
            if (t.equals(_kResult) && i + (u32)1 < toks.count())
                imp._sig._results.add(toks.get(i + (u32)1));
            }
        if (imp._name == (String*)0)
            return fail(String.withCString("import without $name"));
        _imports.add((Object*)imp);
        _impKinds.add((Object*)Number.withU32((u32)0));
        _impModules.add((Object*)imp._importModule);
        _impNames.add((Object*)imp._exportAs);
        _impMuts.add((Object*)Number.withU32((u32)0));
        return true;
        }

    // (type $name (func (param T)* (result T)?))
    bool parseType(String* line)
        {
        Array* toks = WasmWriter.tokensOf(line);
        String* name = (String*)0;
        WasmSig* sig = new WasmSig();
        for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1)
            {
            String* t = (String*)toks.get(i);
            if (t.hasPrefix(_kDollar) && name == (String*)0)
                name = t;
            if (t.equals(_kParam) && i + (u32)1 < toks.count())
                sig._params.add(toks.get(i + (u32)1));
            if (t.equals(_kResult) && i + (u32)1 < toks.count())
                sig._results.add(toks.get(i + (u32)1));
            }
        if (name == (String*)0)
            return fail(String.withCString("type without $name"));
        _namedTypeNames.add((Object*)name);
        _namedTypeSigs.add((Object*)sig);
        return true;
        }

    bool parseTable(String* line)
        {
        _tableExported = line.contains(_kExportTable);
        Array* toks = WasmWriter.tokensOf(line);
        for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1)
            {
            i64 v = WasmWriter.decOf((String*)toks.get(i));
            if (v > (i64)0)
                {
                _tableSize = (u32)v;
                break;
                }
            }
        return true;
        }

    bool parseElem(String* line)
        {
        Array* toks = WasmWriter.tokensOf(line);
        bool sawGet = false;
        for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1)
            {
            String* t = (String*)toks.get(i);
            if (t.equals(_kI32Const) && i + (u32)1 < toks.count())
                _elemBase = WasmWriter.decOf((String*)toks.get(i + (u32)1));
            if (t.equals(_kGlobalGet) && i + (u32)1 < toks.count())
                {
                _elemBaseGlobal = (String*)toks.get(i + (u32)1);
                sawGet = true;
                }
            if (t.hasPrefix(_kDollar))
                {
                // the base global's $id
                if (sawGet)
                    {
                    sawGet = false;
                    continue;
                    }
                _elemFns.add(toks.get(i));
                }
            }
        return true;
        }

    bool parseMemory(String* line)
        {
        _memExported = line.contains(_kExportMemory);
        Array* toks = WasmWriter.tokensOf(line);
        i64 pages = toks.count() > (u32)0 ? WasmWriter.decOf((String*)toks.last()) : (i64)0;
        _memPages = pages != (i64)0 ? (u32)pages : (u32)1;
        return true;
        }

    // (global $name (mut i32) (i32.const K)) |
    // (global $name i32 (i32.const K)), optional inline (export "x")
    bool parseGlobal(String* line)
        {
        Array* toks = WasmWriter.tokensOf(line);
        String* name = (String*)0;
        WasmGlobal* g = new WasmGlobal();
        g._mut = line.contains(_kPMut);
        for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1)
            {
            String* t = (String*)toks.get(i);
            if (t.hasPrefix(_kDollar) && name == (String*)0)
                name = t;
            if (t.equals(_kI32Const) && i + (u32)1 < toks.count())
                g._init = WasmWriter.decOf((String*)toks.get(i + (u32)1));
            if (t.equals(_kExport) && i + (u32)1 < toks.count() && ((String*)toks.get(i + (u32)1)).hasPrefix(_kQuote))
                g._exportAs = WasmWriter.unquote((String*)toks.get(i + (u32)1));
            }
        if (name == (String*)0)
            return fail(String.withCString("global without $name"));
        _globalNames.add((Object*)name);
        _globals.add((Object*)g);
        return true;
        }

    // (data (i32.const A) "…") ;; name — comments survive on data lines,
    // so the closer is the LAST `")` in the line.
    bool parseData(String* line)
        {
        u32 q1 = line.indexOfByte((u8)'"');
        u32 q2 = String.notFound();
        if (line.byteLength() >= (u32)2)
            {
            u32 i = line.byteLength() - (u32)1;
            while (i > (u32)0)
                {
                i = i - (u32)1;
                if (line.byteAt(i) == (u8)'"' && line.byteAt(i + (u32)1) == (u8)')')
                    {
                    q2 = i;
                    break;
                    }
                }
            }
        if (q1 == String.notFound() || q2 == String.notFound() || q2 <= q1)
            return fail(String.withCString("malformed data segment"));
        String* lit = line.substringBytes(q1 + (u32)1, q2 - q1 - (u32)1);
        Array* toks = WasmWriter.tokensOf(line.substringToByte(q1));
        WasmDataSeg* seg = new WasmDataSeg();
        for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1)
            {
            String* t = (String*)toks.get(i);
            if (t.equals(_kI32Const) && i + (u32)1 < toks.count())
                seg._addr = WasmWriter.decOf((String*)toks.get(i + (u32)1));
            if (t.equals(_kGlobalGet) && i + (u32)1 < toks.count())
                seg._addrGlobal = (String*)toks.get(i + (u32)1);
            }
        seg._bytes = WasmWriter.bytesOfDataLiteral(lit);
        _datas.add((Object*)seg);
        return true;
        }

    // (func $name? (export "x")? (param …)* (result T)? — body follows.
    bool parseFuncHeader(String* line)
        {
        _cur = new WasmFn();
        _curDepth = (i32)1;
        Array* toks = WasmWriter.tokensOf(line);
        for (u32 i = (u32)0; i < toks.count(); i = i + (u32)1)
            {
            String* t = (String*)toks.get(i);
            if (t.hasPrefix(_kDollar) && _cur._name == (String*)0 && i > (u32)0 && ((String*)toks.get(i - (u32)1)).equals(_kFunc))
                {
                _cur._name = t;
                continue;
                }
            if (t.equals(_kExport) && i + (u32)1 < toks.count())
                _cur._exportAs = WasmWriter.unquote((String*)toks.get(i + (u32)1));
            if (t.equals(_kParam) && i + (u32)1 < toks.count())
                {
                // (param $name ty) or (param ty)
                if (((String*)toks.get(i + (u32)1)).hasPrefix(_kDollar) && i + (u32)2 < toks.count())
                    {
                    _cur._paramNames.add(toks.get(i + (u32)1));
                    _cur._sig._params.add(toks.get(i + (u32)2));
                    }
                else
                    {
                    _cur._paramNames.add((Object*)String.withFormat("$__p%lu",
                                                                    _cur._paramNames.count()));
                    _cur._sig._params.add(toks.get(i + (u32)1));
                    }
                }
            if (t.equals(_kResult) && i + (u32)1 < toks.count())
                _cur._sig._results.add(toks.get(i + (u32)1));
            }
        return true;
        }

    bool parseModuleLine(String* line)
        {
        if (line.hasPrefix(_kPModule) || line.equals(_kClose))
            return true;
        if (line.hasPrefix(_kSemiSemi))
            return true;
        if (line.hasPrefix(_kPImport))
            return parseImport(line);
        if (line.hasPrefix(_kPType))
            return parseType(line);
        if (line.hasPrefix(_kPTable))
            return parseTable(line);
        if (line.hasPrefix(_kPElem))
            return parseElem(line);
        if (line.hasPrefix(_kPMemory))
            return parseMemory(line);
        if (line.hasPrefix(_kPGlobal))
            return parseGlobal(line);
        if (line.hasPrefix(_kPData))
            return parseData(line);
        if (line.hasPrefix(_kPFunc))
            return parseFuncHeader(line);
        return fail(String.withFormat("unrecognised module-level form: %s",
                                      line.cString()));
        }

    // ── Body encoding ────────────────────────────────────────────────────
    // The label immediates: br / br_if.
    bool encodeLabelImm(WasmBuf* body, Array* toks, Array* labels, String* fnLabel)
        {
        if (toks.count() < (u32)2)
            return fail(String.withFormat("br needs a label (in %s)", fnLabel.cString()));
        i32 depth = WasmWriter.depthOf(labels, (String*)toks.get((u32)1));
        if (depth < (i32)0)
            return fail(String.withFormat("unknown label '%s' (in %s)",
                                          ((String*)toks.get((u32)1)).cString(), fnLabel.cString()));
        body.pU((u64)(u32)depth);
        return true;
        }

    // br_table $L0 $L1 … $Ldefault (last is the default).
    bool encodeBrTable(WasmBuf* body, Array* toks, Array* labels, String* fnLabel)
        {
        if (toks.count() < (u32)2)
            return fail(String.withFormat("br_table needs labels (in %s)",
                                          fnLabel.cString()));
        body.pU((u64)(toks.count() - (u32)2));
        for (u32 i = (u32)1; i < toks.count(); i = i + (u32)1)
            {
            i32 depth = WasmWriter.depthOf(labels, (String*)toks.get(i));
            if (depth < (i32)0)
                return fail(String.withFormat("unknown br_table label '%s' (in %s)",
                                              ((String*)toks.get(i)).cString(), fnLabel.cString()));
            body.pU((u64)(u32)depth);
            }
        return true;
        }

    // Named-index immediates: local.* / global.* / call.
    bool encodeIndexImm(WasmBuf* body, Array* toks, Map* index,
                        string needMsg, string unknownFmt, String* fnLabel)
        {
        if (toks.count() < (u32)2)
            return fail(String.withFormat("%s (in %s)", needMsg, fnLabel.cString()));
        Object* idx = index.get((Hashable*)toks.get((u32)1));
        if (idx == (Object*)0)
            return fail(String.withFormat(unknownFmt,
                                          ((String*)toks.get((u32)1)).cString(), fnLabel.cString()));
        body.pU((u64)((Number*)idx).asU32());
        return true;
        }

    bool encodeConstImm(WasmBuf* body, Array* toks, u32 imm, String* fnLabel)
        {
        if (imm == (u32)WIMM_I32 || imm == (u32)WIMM_I64)
            {
            if (toks.count() < (u32)2)
                return fail(String.withFormat("const needs a value (in %s)",
                                              fnLabel.cString()));
            body.pS(WasmWriter.parseI64((String*)toks.get((u32)1)));
            return true;
            }
        if (imm == (u32)WIMM_F32)
            {
            if (toks.count() < (u32)2)
                return fail(String.withFormat("f32.const needs a value (in %s)",
                                              fnLabel.cString()));
            u32 fb = WasmWriter.dblToFltBits(
                WasmWriter.hexFloatBits((String*)toks.get((u32)1)));
            for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                body.p8((fb >> ((u32)8 * k)) & (u32)$FF);
            return true;
            }
        // WIMM_F64
        if (toks.count() < (u32)2)
            return fail(String.withFormat("f64.const needs a value (in %s)",
                                          fnLabel.cString()));
        u64 bits = WasmWriter.hexFloatBits((String*)toks.get((u32)1));
        for (u32 k = (u32)0; k < (u32)8; k = k + (u32)1)
            body.p8((u32)((bits >> ((u64)8 * (u64)k)) & (u64)$FF));
        return true;
        }

    // One instruction line.
    bool encodeLine(WasmBuf* body, String* line, Map* localIndex,
                    Array* labels, String* fnLabel)
        {
        Array* toks = WasmWriter.tokensOf(line);
        if (toks.count() == (u32)0)
            return true;
        String* opName = (String*)toks.get((u32)0);

        if (opName.equals(_kBlock) || opName.equals(_kLoop))
            {
            body.p8(opName.equals(_kBlock) ? (u32)$02 : (u32)$03);
            body.p8((u32)$40); // void block type
            labels.add(toks.count() > (u32)1 ? toks.get((u32)1) : (Object*)_kEmpty);
            return true;
            }
        if (opName.equals(_kIf))
            {
            body.p8((u32)$04);
            body.p8((u32)$40);
            labels.add(toks.count() > (u32)1 ? toks.get((u32)1) : (Object*)_kEmpty);
            return true;
            }
        if (opName.equals(_kElse))
            {
            body.p8((u32)$05);
            return true;
            }
        if (opName.equals(_kEnd))
            {
            body.p8((u32)$0B);
            if (labels.count() > (u32)0)
                labels.removeAt(labels.count() - (u32)1);
            return true;
            }

        if (opName.equals(_kCallIndirect) || opName.equals(_kRetCallIndirect))
            {
            // (return_)call_indirect (type $name) -> 0x11/0x13 typeidx tableidx(0).
            Object* ti = toks.count() > (u32)2
                             ? _namedTypeIndex.get((Hashable*)toks.get((u32)2))
                             : (Object*)0;
            if (ti == (Object*)0)
                return fail(String.withFormat("call_indirect with unknown type (in %s)",
                                              fnLabel.cString()));
            body.p8(opName.equals(_kCallIndirect) ? (u32)$11 : (u32)$13);
            body.pU((u64)((Number*)ti).asU32());
            body.p8((u32)$00);
            return true;
            }
        if (opName.equals(_kMemSize))
            {
            body.p8((u32)$3F);
            body.p8((u32)$00);
            return true;
            }
        if (opName.equals(_kMemGrow))
            {
            body.p8((u32)$40);
            body.p8((u32)$00);
            return true;
            }

        Object* encO = _ops.get((Hashable*)opName);
        if (encO == (Object*)0)
            return fail(String.withFormat("unknown instruction '%s' (in %s)",
                                          opName.cString(), fnLabel.cString()));
        u32 enc = ((Number*)encO).asU32();
        u32 encByte = enc & (u32)$FF;
        u32 encImm = (enc >> (u32)8) & (u32)$FF;
        u32 encExtra = enc >> (u32)16;
        body.p8(encByte);
        // extra is the 0xFC/0xFD sub-opcode for prefixed instructions and the
        // natural-alignment log2 for memory ops — dispatch on the prefix.
        if (encByte == (u32)$FC || encByte == (u32)$FD)
            {
            body.pU((u64)encExtra);
            if (opName.equals(_kMemCopy))
                {
                body.p8((u32)0);
                body.p8((u32)0);
                }
            else if (opName.equals(_kMemFill))
                {
                body.p8((u32)0);
                }
            }

        if (encImm == (u32)WIMM_I32 || encImm == (u32)WIMM_I64 || encImm == (u32)WIMM_F32 || encImm == (u32)WIMM_F64)
            {
            if (!encodeConstImm(body, toks, encImm, fnLabel))
                return false;
            }
        else if (encImm == (u32)WIMM_LABEL)
            {
            if (!encodeLabelImm(body, toks, labels, fnLabel))
                return false;
            }
        else if (encImm == (u32)WIMM_BRTABLE)
            {
            if (!encodeBrTable(body, toks, labels, fnLabel))
                return false;
            }
        else if (encImm == (u32)WIMM_LOCAL)
            {
            if (!encodeIndexImm(body, toks, localIndex, "local op needs a name",
                                "unknown local '%s' (in %s)", fnLabel))
                return false;
            }
        else if (encImm == (u32)WIMM_GLOBAL)
            {
            if (!encodeIndexImm(body, toks, _globalIndex, "global op needs a name",
                                "unknown global '%s' (in %s)", fnLabel))
                return false;
            }
        else if (encImm == (u32)WIMM_CALL)
            {
            if (!encodeIndexImm(body, toks, _fnIndex, "call needs a target",
                                "unknown function '%s' (in %s)", fnLabel))
                return false;
            }
        else if (encImm == (u32)WIMM_LANE)
            {
            // One lane-index byte (i32x4.extract_lane 2).
            if (toks.count() < (u32)2)
                return fail(String.withFormat("lane op needs an index (in %s)",
                                              fnLabel.cString()));
            body.p8((u32)WasmWriter.parseI64((String*)toks.get((u32)1)));
            }
        else if (encImm == (u32)WIMM_LANES16)
            {
            // Sixteen lane-index bytes (i8x16.shuffle 0 2 4 …).
            if (toks.count() < (u32)17)
                return fail(String.withFormat("shuffle needs 16 lanes (in %s)",
                                              fnLabel.cString()));
            for (u32 li = (u32)1; li <= (u32)16; li = li + (u32)1)
                body.p8((u32)WasmWriter.parseI64((String*)toks.get(li)));
            }
        if (encImm == (u32)WIMM_MEMPAIR)
            {
            // Optional `offset=N` immediate token (the generated runtime's
            // free-list uses it); align stays the natural hint — for the
            // 0xFD-prefixed v128.load/store that is 16 bytes (log2 4).
            u64 memOff = (u64)0;
            for (u32 ti = (u32)1; ti < toks.count(); ti = ti + (u32)1)
                {
                String* t = (String*)toks.get(ti);
                if (t.hasPrefix(_kOffsetEq))
                    memOff = (u64)WasmWriter.parseI64(t.substringFromByte((u32)7));
                }
            body.pU(encByte == (u32)$FD ? (u64)4 : (u64)encExtra); // natural align (log2)
            body.pU(memOff);
            }
        return true;
        }

    // Locals declaration prologue: run-length-encode by type.
    bool encodeLocals(WasmBuf* body, WasmFn* f, String* fnLabel)
        {
        Array* gCounts = new Array(); // Number@
        Array* gTypes = new Array();  // String@
        for (u32 i = (u32)0; i < f._localTypes.count(); i = i + (u32)1)
            {
            String* t = (String*)f._localTypes.get(i);
            if (gTypes.count() > (u32)0 && ((String*)gTypes.last()).equals(t))
                {
                u32 c = ((Number*)gCounts.last()).asU32();
                gCounts.set(gCounts.count() - (u32)1, (Object*)Number.withU32(c + (u32)1));
                }
            else
                {
                gCounts.add((Object*)Number.withU32((u32)1));
                gTypes.add((Object*)t);
                }
            }
        body.pU((u64)gCounts.count());
        _vtOk = true;
        for (u32 i = (u32)0; i < gCounts.count(); i = i + (u32)1)
            {
            body.pU((u64)((Number*)gCounts.get(i)).asU32());
            body.p8(valType((String*)gTypes.get(i)));
            }
        if (!_vtOk)
            return fail(String.withFormat("unknown local type (in %s)",
                                          fnLabel.cString()));
        return true;
        }

    WasmBuf* encodeBody(WasmFn* f)
        {
        String* fnLabel = f._name != (String*)0 ? f._name
                                                : (f._exportAs != (String*)0 ? f._exportAs : _kQuestion);

        // Locals: index space = params then locals.
        Map* localIndex = new Map();
        u32 li = (u32)0;
        for (u32 i = (u32)0; i < f._paramNames.count(); i = i + (u32)1)
            {
            localIndex.set((Hashable*)f._paramNames.get(i), (Object*)Number.withU32(li));
            li = li + (u32)1;
            }
        for (u32 i = (u32)0; i < f._localNames.count(); i = i + (u32)1)
            {
            localIndex.set((Hashable*)f._localNames.get(i), (Object*)Number.withU32(li));
            li = li + (u32)1;
            }

        WasmBuf* body = new WasmBuf();
        if (!encodeLocals(body, f, fnLabel))
            return (WasmBuf*)0;

        // Label stack for depth resolution. `if`/`block`/`loop` push; `else`
        // keeps its frame; `end` pops. "" = anonymous.
        Array* labels = new Array();
        for (u32 bl = (u32)0; bl < f._bodyLines.count(); bl = bl + (u32)1)
            if (!encodeLine(body, (String*)f._bodyLines.get(bl),
                            localIndex, labels, fnLabel))
                return (WasmBuf*)0;

        body.p8((u32)$0B); // end of function
        return body;
        }

    // ── Index spaces ─────────────────────────────────────────────────────
    void buildIndexes(void)
        {
        _fnIndex = new Map();
        u32 fi = (u32)0;
        for (u32 i = (u32)0; i < _imports.count(); i = i + (u32)1)
            {
            WasmFn* f = (WasmFn*)_imports.get(i);
            _fnIndex.set((Hashable*)f._name, (Object*)Number.withU32(fi));
            fi = fi + (u32)1;
            }
        for (u32 i = (u32)0; i < _funcs.count(); i = i + (u32)1)
            {
            WasmFn* f = (WasmFn*)_funcs.get(i);
            if (f._name != (String*)0)
                _fnIndex.set((Hashable*)f._name, (Object*)Number.withU32(fi));
            fi = fi + (u32)1;
            }
        // Global index space: IMPORTED globals first, then the module's own.
        _globalIndex = new Map();
        for (u32 i = (u32)0; i < _importedGlobalNames.count(); i = i + (u32)1)
            _globalIndex.set((Hashable*)_importedGlobalNames.get(i),
                             (Object*)Number.withU32(i));
        for (u32 i = (u32)0; i < _globalNames.count(); i = i + (u32)1)
            _globalIndex.set((Hashable*)_globalNames.get(i),
                             (Object*)Number.withU32(_importedGlobalNames.count() + i));

        // Type section: dedupe signatures. Named types first (call_indirect
        // references them by name), then the function signatures — typeFor
        // dedupes structurally either way.
        _types = new Array();
        _typeIndex = new Map();
        _namedTypeIndex = new Map();
        for (u32 i = (u32)0; i < _namedTypeNames.count(); i = i + (u32)1)
            _namedTypeIndex.set((Hashable*)_namedTypeNames.get(i),
                                (Object*)typeFor((WasmSig*)_namedTypeSigs.get(i)));
        for (u32 i = (u32)0; i < _imports.count(); i = i + (u32)1)
            typeFor(((WasmFn*)_imports.get(i))._sig);
        for (u32 i = (u32)0; i < _funcs.count(); i = i + (u32)1)
            typeFor(((WasmFn*)_funcs.get(i))._sig);
        }

    // ── Emission: one section per method ─────────────────────────────────
    bool emitTypes(WasmBuf* out)
        {
        _vtOk = true;
        WasmBuf* sec = new WasmBuf();
        sec.pU((u64)_types.count());
        for (u32 i = (u32)0; i < _types.count(); i = i + (u32)1)
            {
            WasmSig* s = (WasmSig*)_types.get(i);
            sec.p8((u32)$60);
            sec.pU((u64)s._params.count());
            for (u32 j = (u32)0; j < s._params.count(); j = j + (u32)1)
                sec.p8(valType((String*)s._params.get(j)));
            sec.pU((u64)s._results.count());
            for (u32 j = (u32)0; j < s._results.count(); j = j + (u32)1)
                sec.p8(valType((String*)s._results.get(j)));
            }
        if (!_vtOk)
            return fail(String.withCString("unknown value type in signature"));
        out.section((u32)1, sec);
        return true;
        }

    void emitImports(WasmBuf* out)
        {
        if (_impKinds.count() == (u32)0)
            return;
        // FILE order, mixed kinds — a function import's index among
        // FUNCTIONS is its position among the kind-0 rows.
        WasmBuf* sec = new WasmBuf();
        sec.pU((u64)_impKinds.count());
        u32 fk = (u32)0;
        for (u32 i = (u32)0; i < _impKinds.count(); i = i + (u32)1)
            {
            u32 kind = ((Number*)_impKinds.get(i)).asU32();
            sec.pName((String*)_impModules.get(i));
            sec.pName((String*)_impNames.get(i));
            if (kind == (u32)0)
                {
                WasmFn* f = (WasmFn*)_imports.get(fk);
                fk = fk + (u32)1;
                sec.p8((u32)$00);
                sec.pU((u64)typeFor(f._sig).asU32());
                }
            else if (kind == (u32)1)
                {
                sec.p8((u32)$01);
                sec.p8((u32)$70); // funcref
                sec.p8((u32)$00);
                sec.pU((u64)0); // limits: min 0
                }
            else if (kind == (u32)2)
                {
                sec.p8((u32)$02);
                sec.p8((u32)$00);
                sec.pU((u64)0);
                }
            else
                {
                sec.p8((u32)$03);
                sec.p8((u32)$7F); // i32
                sec.p8(((Number*)_impMuts.get(i)).asU32() != (u32)0 ? (u32)$01 : (u32)$00);
                }
            }
        out.section((u32)2, sec);
        }

    void emitFuncSection(WasmBuf* out)
        {
        WasmBuf* sec = new WasmBuf();
        sec.pU((u64)_funcs.count());
        for (u32 i = (u32)0; i < _funcs.count(); i = i + (u32)1)
            sec.pU((u64)typeFor(((WasmFn*)_funcs.get(i))._sig).asU32());
        out.section((u32)3, sec);
        }

    void emitTableAndMemory(WasmBuf* out)
        {
        // table section
        if (_tableSize > (u32)0 && !_tableImported)
            {
            WasmBuf* tsec = new WasmBuf();
            tsec.pU((u64)1);
            tsec.p8((u32)$70);
            tsec.p8((u32)$00);
            tsec.pU((u64)_tableSize);
            out.section((u32)4, tsec);
            }
        if (!_memImported)
            {
            WasmBuf* sec = new WasmBuf(); // memory section
            sec.pU((u64)1);
            sec.p8((u32)$00);
            sec.pU((u64)_memPages);
            out.section((u32)5, sec);
            }
        }

    void emitGlobals(WasmBuf* out)
        {
        if (_globals.count() == (u32)0)
            return;
        WasmBuf* sec = new WasmBuf();
        sec.pU((u64)_globals.count());
        for (u32 i = (u32)0; i < _globals.count(); i = i + (u32)1)
            {
            WasmGlobal* g = (WasmGlobal*)_globals.get(i);
            sec.p8((u32)$7F); // i32
            sec.p8(g._mut ? (u32)$01 : (u32)$00);
            sec.p8((u32)$41);
            sec.pS(g._init); // i32.const init
            sec.p8((u32)$0B);
            }
        out.section((u32)6, sec);
        }

    // Memory export first, then funcs in order, then exported globals.
    void emitExports(WasmBuf* out)
        {
        WasmBuf* sec = new WasmBuf();
        u32 nExports = _memExported ? (u32)1 : (u32)0;
        if (_tableExported)
            nExports = nExports + (u32)1;
        for (u32 i = (u32)0; i < _funcs.count(); i = i + (u32)1)
            if (((WasmFn*)_funcs.get(i))._exportAs != (String*)0)
                nExports = nExports + (u32)1;
        for (u32 i = (u32)0; i < _globals.count(); i = i + (u32)1)
            if (((WasmGlobal*)_globals.get(i))._exportAs.byteLength() > (u32)0)
                nExports = nExports + (u32)1;
        sec.pU((u64)nExports);
        if (_memExported)
            {
            sec.pName(_kMemoryName);
            sec.p8((u32)$02);
            sec.pU((u64)0);
            }
        if (_tableExported)
            {
            sec.pName(_kTableName);
            sec.p8((u32)$01);
            sec.pU((u64)0);
            }
        u32 fj = _imports.count();
        for (u32 i = (u32)0; i < _funcs.count(); i = i + (u32)1)
            {
            WasmFn* f = (WasmFn*)_funcs.get(i);
            if (f._exportAs != (String*)0)
                {
                sec.pName(f._exportAs);
                sec.p8((u32)$00);
                sec.pU((u64)fj);
                }
            fj = fj + (u32)1;
            }
        for (u32 gi = (u32)0; gi < _globals.count(); gi = gi + (u32)1)
            {
            WasmGlobal* g = (WasmGlobal*)_globals.get(gi);
            if (g._exportAs.byteLength() == (u32)0)
                continue;
            sec.pName(g._exportAs);
            sec.p8((u32)$03);
            sec.pU((u64)(_importedGlobalNames.count() + gi));
            }
        out.section((u32)7, sec);
        }

    bool emitElem(WasmBuf* out)
        {
        if (_elemFns.count() == (u32)0)
            return true;
        WasmBuf* sec = new WasmBuf();
        sec.pU((u64)1);
        sec.pU((u64)0); // active, table 0
        if (_elemBaseGlobal != (String*)0)
            {
            Object* gi = _globalIndex.get((Hashable*)_elemBaseGlobal);
            if (gi == (Object*)0)
                return fail(String.withFormat("elem offset names unknown global '%s'",
                                              _elemBaseGlobal.cString()));
            sec.p8((u32)$23);
            sec.pU((u64)((Number*)gi).asU32());
            sec.p8((u32)$0B);
            }
        else
            {
            sec.p8((u32)$41);
            sec.pS(_elemBase < (i64)0 ? (i64)1 : _elemBase);
            sec.p8((u32)$0B);
            }
        sec.pU((u64)_elemFns.count());
        for (u32 i = (u32)0; i < _elemFns.count(); i = i + (u32)1)
            {
            String* fname = (String*)_elemFns.get(i);
            Object* idx = _fnIndex.get((Hashable*)fname);
            if (idx == (Object*)0)
                return fail(String.withFormat("elem names unknown function '%s'",
                                              fname.cString()));
            sec.pU((u64)((Number*)idx).asU32());
            }
        out.section((u32)9, sec);
        return true;
        }

    bool emitCode(WasmBuf* out)
        {
        WasmBuf* sec = new WasmBuf();
        sec.pU((u64)_funcs.count());
        for (u32 i = (u32)0; i < _funcs.count(); i = i + (u32)1)
            {
            WasmBuf* body = encodeBody((WasmFn*)_funcs.get(i));
            if (body == (WasmBuf*)0)
                return false;
            sec.pU((u64)body.count());
            sec.appendBuf(body);
            }
        out.section((u32)10, sec);
        return true;
        }

    bool emitData(WasmBuf* out)
        {
        if (_datas.count() == (u32)0)
            return true;
        WasmBuf* sec = new WasmBuf();
        sec.pU((u64)_datas.count());
        for (u32 i = (u32)0; i < _datas.count(); i = i + (u32)1)
            {
            WasmDataSeg* d = (WasmDataSeg*)_datas.get(i);
            sec.pU((u64)0); // active, memory 0
            if (d._addrGlobal != (String*)0)
                {
                Object* gi = _globalIndex.get((Hashable*)d._addrGlobal);
                if (gi == (Object*)0)
                    return fail(String.withFormat("data offset names unknown global '%s'",
                                                  d._addrGlobal.cString()));
                sec.p8((u32)$23);
                sec.pU((u64)((Number*)gi).asU32());
                sec.p8((u32)$0B);
                }
            else
                {
                sec.p8((u32)$41);
                sec.pS(d._addr);
                sec.p8((u32)$0B);
                }
            sec.pU((u64)d._bytes.length());
            sec.buf().append(d._bytes);
            }
        out.section((u32)11, sec);
        return true;
        }

    // `name` custom section — function names for legible stack traces.
    // Count = imports+funcs with names; indices are the FULL function index
    // space (imports first); names drop the leading `$`.
    void emitNames(WasmBuf* out)
        {
        WasmBuf* names = new WasmBuf();
        names.pName(_kNameName);
        WasmBuf* fnNames = new WasmBuf();
        u32 named = (u32)0;
        for (u32 i = (u32)0; i < _imports.count(); i = i + (u32)1)
            if (((WasmFn*)_imports.get(i))._name != (String*)0)
                named = named + (u32)1;
        for (u32 i = (u32)0; i < _funcs.count(); i = i + (u32)1)
            if (((WasmFn*)_funcs.get(i))._name != (String*)0)
                named = named + (u32)1;
        fnNames.pU((u64)named);
        u32 fj = (u32)0;
        for (u32 i = (u32)0; i < _imports.count(); i = i + (u32)1)
            {
            WasmFn* f = (WasmFn*)_imports.get(i);
            if (f._name != (String*)0)
                {
                fnNames.pU((u64)fj);
                fnNames.pName(f._name.substringFromByte((u32)1));
                }
            fj = fj + (u32)1;
            }
        for (u32 i = (u32)0; i < _funcs.count(); i = i + (u32)1)
            {
            WasmFn* f = (WasmFn*)_funcs.get(i);
            if (f._name != (String*)0)
                {
                fnNames.pU((u64)fj);
                fnNames.pName(f._name.substringFromByte((u32)1));
                }
            fj = fj + (u32)1;
            }
        names.p8((u32)$01);
        names.pU((u64)fnNames.count());
        names.appendBuf(fnNames);
        out.section((u32)0, names);
        }

    // ── The whole module ─────────────────────────────────────────────────
    Data* moduleFromWat(String* watText)
        {
        _imports = new Array();
        _funcs = new Array();
        _datas = new Array();
        _globals = new Array();
        _globalNames = new Array();
        _impKinds = new Array();
        _impModules = new Array();
        _impNames = new Array();
        _impMuts = new Array();
        _importedGlobalNames = new Array();
        _memImported = false;
        _tableImported = false;
        _tableExported = false;
        _elemBaseGlobal = (String*)0;
        _memPages = (u32)1;
        _memExported = false;
        _tableSize = (u32)0;
        _elemBase = (i64)-1;
        _elemFns = new Array();
        _namedTypeNames = new Array();
        _namedTypeSigs = new Array();
        _cur = (WasmFn*)0;
        _curDepth = (i32)0; // tracked so the closing `)` of a func is found

        Array* rawLines = watText.splitOnByte((u8)10);
        for (u32 ln = (u32)0; ln < rawLines.count(); ln = ln + (u32)1)
            {
            String* line = ((String*)rawLines.get(ln)).trimmed();
            // Strip ;; comments (never inside a string literal in this
            // dialect except data segments, which are handled whole-line).
            if (!line.hasPrefix(_kPData))
                {
                u32 c = line.byteIndexOf(_kSemiSemi);
                if (c != String.notFound())
                    line = line.substringToByte(c).trimmed();
                }
            if (line.byteLength() == (u32)0)
                continue;
            if (_cur != (WasmFn*)0)
                {
                if (!parseBodyLine(line))
                    return (Data*)0;
                continue;
                }
            if (!parseModuleLine(line))
                return (Data*)0;
            }
        if (_cur != (WasmFn*)0)
            {
            fail(String.withCString("unterminated (func"));
            return (Data*)0;
            }

        buildIndexes();

        WasmBuf* out = new WasmBuf();
        out.p8((u32)$00);
        out.p8((u32)$61);
        out.p8((u32)$73);
        out.p8((u32)$6D);
        out.p8((u32)$01);
        out.p8((u32)$00);
        out.p8((u32)$00);
        out.p8((u32)$00);

        if (!emitTypes(out))
            return (Data*)0;
        emitImports(out);
        emitFuncSection(out);
        emitTableAndMemory(out);
        emitGlobals(out);
        emitExports(out);
        if (!emitElem(out))
            return (Data*)0;
        if (!emitCode(out))
            return (Data*)0;
        if (!emitData(out))
            return (Data*)0;
        emitNames(out);
        return out.buf();
        }
    }
