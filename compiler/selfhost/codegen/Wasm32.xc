// Wasm32.xc — the wasm32 back end, ported. IR text in, WAT out.
// =========================================================================
//
// self-hosting, wasm stage A. The port of XTWasmBackend: every function is one
// `loop` wrapping a `br_table` on a $pc local, every SSA value gets a wasm
// local, narrow integers live canonicalised in i32 locals, aggregates and
// pinned locals live in a linear-memory shadow frame off $__sp. The ORACLE is
// `xcc-cg-wasm32 -O0` over the same IR text — the WAT must come out byte for
// byte the same (wasm-diff.sh).
//
// The pinned-local / agg-slot address seeds walk their keys in ASCENDING
// value-id order, matching the original's sorted walk (it once enumerated
// an NSMutableDictionary — hash order — and this port briefly simulated
// CFBasicHash to match; the original was fixed instead, per the rule).

#import "Foundation.xc"
#import "Ir.xc"


// ── Per-function emission state ────────────────────────────────────────────
class WasmFnCtx
{
    IRFunc* _fn;
    u32*    _pinnedOff;     // value id -> frame offset, $FFFFFFFF = none
    u32*    _aggSlot;       // value id -> frame offset, $FFFFFFFF = none
    bool*   _declared;      // value id -> has a wasm local (params included)
    u32     _nIds;
    Array*  _pinnedKeys;    // Number@ ids, dictionary INSERTION order
    Array*  _aggKeys;       // Number@ ids, dictionary INSERTION order
    u32     _frameSize;
    bool    _hasSret;

    void init(void)
    {
        _pinnedKeys = new Array();
        _aggKeys = new Array();
        _frameSize = (u32)0;
        _hasSret = false;
        _nIds = (u32)0;
    }

    void sizeTo(u32 n)
    {
        _nIds = n;
        u32 m = n == (u32)0 ? (u32)1 : n;
        _pinnedOff = new u32[m];
        _aggSlot = new u32[m];
        _declared = new bool[m];
        for (u32 i = (u32)0; i < m; i = i + (u32)1) {
            _pinnedOff[i] = (u32)$FFFFFFFF;
            _aggSlot[i] = (u32)$FFFFFFFF;
            _declared[i] = false;
        }
    }

    // NOT named `release` — that is the ARC hook, and ARC would run it a
    // second time at scope exit, double-freeing the raw arrays.
    void dropSlots(void)
    {
        if (_pinnedOff != 0) delete _pinnedOff;
        if (_aggSlot != 0) delete _aggSlot;
        if (_declared != 0) delete _declared;
        _pinnedOff = (u32*)0;
        _aggSlot = (u32*)0;
        _declared = (bool*)0;
    }
}

// ── Structured-emission plan (one per function, -O1+) ─────────────────────
// The dominator-tree relooper's analysis result, the twin of XTWasmCFGPlan:
// successor lists in terminator-operand order, a DFS reverse postorder,
// immediate dominators, natural-loop headers, merge nodes (>= 2 forward
// in-EDGES), and each block's merge-node dominator children in RPO order.
// Every collection is an array walked in a defined order — the original
// enumerates nothing hash-ordered here, so neither does this.
class WasmCFGPlan
{
    u32    _n;
    Array* _succs;        // per block: Array@ of Number@ edge targets
    i32*   _rpoIndex;     // per block, -1 = unreachable
    i32*   _idom;         // per block, -1 = none (entry points at itself)
    bool*  _loopHeader;
    bool*  _mergeNode;
    Array* _mergeKids;    // per block: Array@ of Number@, RPO order

    void init(void)
    {
        _succs = new Array();
        _mergeKids = new Array();
        _n = (u32)0;
    }

    void sizeTo(u32 n)
    {
        _n = n;
        u32 m = n == (u32)0 ? (u32)1 : n;
        _rpoIndex = new i32[m];
        _idom = new i32[m];
        _loopHeader = new bool[m];
        _mergeNode = new bool[m];
        for (u32 i = (u32)0; i < m; i = i + (u32)1) {
            _rpoIndex[i] = (i32)-1;
            _idom[i] = (i32)-1;
            _loopHeader[i] = false;
            _mergeNode[i] = false;
        }
    }

    // NOT named `release` — the WasmFnCtx rule: ARC would run that a second
    // time at scope exit, double-freeing the raw arrays.
    void dropSlots(void)
    {
        if (_rpoIndex != 0) delete _rpoIndex;
        if (_idom != 0) delete _idom;
        if (_loopHeader != 0) delete _loopHeader;
        if (_mergeNode != 0) delete _mergeNode;
        _rpoIndex = (i32*)0;
        _idom = (i32*)0;
        _loopHeader = (bool*)0;
        _mergeNode = (bool*)0;
    }
}

class Wasm32
{
    IRModule* _m;
    Map*      _symByName;       // name -> IRSymbol@
    Map*      _symAddr;         // name -> Number@ linear address
    Array*    _constAddr;       // Number@ addr or (Object*)0 per constant id
    u32       _dataEnd;
    Array*    _dataSegs;        // String@
    Map*      _importSigs;      // name -> String@ "(param i32) (result i32)"
    Array*    _importNames;     // String@, insertion order (sorted at print)
    Map*      _importPkg;       // name -> String@ package
    bool      _fatalImport;     // a C-variadic import was called (task #34)

    bool fatalImport(void) { return _fatalImport; }
    Map*      _definedFns;      // name -> Number@ 1
    Map*      _fnTableIndex;    // name -> Number@ funcref index
    Array*    _fnTableOrder;    // String@
    Array*    _indirectKeys;    // String@ sig text
    Array*    _indirectNames;   // String@ "itN", parallel
    bool      _needsARC;
    bool      _needsAlloc;
    bool      _needsHeapInfo;
    Array*    _newSuffixes;     // String@, deduped
    u32       _optLevel;        // 0 = dispatch loop; 1+ = structured CFG
    bool      _tailCalls;       // -x-wasm32,return-call
    // Local-name map (-O1+), the twin of the original's sValueRank: locals
    // are named by the RANK of the value id among the ids in the FINAL body
    // (ascending), because the original's raw ids carry gaps (values its
    // passes allocated and later killed) that no after-the-fact numbering
    // can reproduce. 0 (unset) at -O0 — raw ids, the oracle text.
    u32*      _vRank;
    u32       _vRankN;
    // ── Multi-module modes (W2) — the twins of sEmitLib / sLinkLibs ──────
    bool      _emitLib;         // this module IS a library (relocatable)
    bool      _linkLibs;        // this module is an APP that #imports .wasm libs
    Array*    _libImage;        // emit-lib: Number@ bytes, ONE relative image
    Array*    _libRelocAddr;    // emit-lib: Number@ word offsets
    Array*    _libRelocIsFn;    // emit-lib: Number@ 1=table index, 0=data addr,
                                //   2=another library's data (its __addr_ getter)
    Array*    _libRelocVal;     // emit-lib: Number@ value (index / rel addr),
                                //   or String@ the symbol name for kind 2
    Array*    _getterNames;     // emit-lib: String@ __addr_ getter symbols
    Array*    _getterOffs;      // emit-lib: Number@ their offsets
    Map*      _externAddrPkg;   // link-libs/emit-lib: extern data sym name -> pkg
    Array*    _externAddrOrder; // link-libs/emit-lib: registration order
    Array*    _fixupAddrs;      // link-libs: Number@ app vtable word addrs
    Array*    _fixupNames;      // link-libs: String@ the extern sym each holds
    bool      _needsWeakReg;    // emit-lib: WeakRegister opcodes present
    bool      _needsWeakUnreg;  // emit-lib: WeakUnregister opcodes present
    bool      _needsItab;       // ProtoDispatch/ProtoLoad present: emit $__xtc_itab

    void init(void) { _optLevel = (u32)0; _tailCalls = false; _vRank = (u32*)0; _vRankN = (u32)0; }

    void setEmitLib(bool on)  { _emitLib = on; }
    void setLinkLibs(bool on) { _linkLibs = on; }

    u32 vnum(u32 vid)
    {
        if (_vRank == 0) return vid;
        if (vid < _vRankN && _vRank[vid] != (u32)$FFFFFFFF) return _vRank[vid];
        return vid;
    }

    void dropRank(void)
    {
        if (_vRank != 0) delete _vRank;
        _vRank = (u32*)0;
        _vRankN = (u32)0;
    }

    void markSeen(bool* seen, u32 nIds, Array* list)
    {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            markSeenOne(seen, nIds, (IRInsn*)list.get(i));
    }

    void markSeenOne(bool* seen, u32 nIds, IRInsn* n)
    {
        if (n.res() != 0 && n.res().pid() < nIds) seen[n.res().pid()] = true;
        if (n.memRes() != 0 && n.memRes().pid() < nIds) seen[n.memRes().pid()] = true;
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() != (u8)OPK_USE || o.val() == 0) continue;
            if (o.val().pid() < nIds) seen[o.val().pid()] = true;
        }
    }

    // Mirrors +[XTWasmBackend setOptLevel:]: at -O1+ every reducible
    // function is emitted as real nested block/loop/if; -O0 keeps the
    // br_table dispatch loop byte for byte.
    void setOptLevel(u32 level) { _optLevel = level; }
    void setTailCalls(bool on)  { _tailCalls = on; }

    // The key arrays in ascending numeric order (insertion sort — the sets
    // are a handful of value ids). Matches the original's sorted walk of
    // pinnedOffset / aggSlot keys.
    static Array* ascendingKeys(Array* keys)
    {
        Array* out = new Array();
        for (u32 i = (u32)0; i < keys.count(); i = i + (u32)1)
            out.add(keys.get(i));
        for (u32 i = (u32)1; i < out.count(); i = i + (u32)1) {
            u32 j = i;
            while (j > (u32)0
                   && ((Number*)out.get(j - (u32)1)).asU32()
                      > ((Number*)out.get(j)).asU32()) {
                Object* t = out.get(j - (u32)1);
                out.set(j - (u32)1, out.get(j));
                out.set(j, t);
                j = j - (u32)1;
            }
        }
        return out;
    }

    // ── Widths (the type-width invariant's backend side) ─────────────────
    static bool isPtrTy(String* t)
    { return t != (String*)0 && t.hasPrefix(String.withCString("Ptr(")); }

    static bool isAggTy(String* t)
    { return t != (String*)0 && t.hasPrefix(String.withCString("Agg(")); }

    static bool isVecTy(String* t)
    { return t != (String*)0 && t.hasPrefix(String.withCString("Vec(")); }

    // The lane type a Vec(lane) carries — brace-matched, as pointeeOf does.
    static String* laneOf(String* t)
    {
        if (!Wasm32.isVecTy(t)) return (String*)0;
        u32 depth = (u32)0;
        for (u32 i = (u32)4; i < t.byteLength(); i = i + (u32)1) {
            u8 c = t.byteAt(i);
            if (c == (u8)'(') depth = depth + (u32)1;
            else if (c == (u8)')') {
                if (depth == (u32)0) return t.substringBytes((u32)4, i - (u32)4);
                depth = depth - (u32)1;
            }
            else if (c == (u8)',' && depth == (u32)0)
                return t.substringBytes((u32)4, i - (u32)4);
        }
        return (String*)0;
    }

    // The wasm SIMD shape prefix for a vector's lane type ("i32x4" etc.);
    // 0 for a lane wasm has no 128-bit shape for (never produced by the
    // vectoriser).
    static String* laneShape(String* lane)
    {
        if (lane == (String*)0) return (String*)0;
        if (lane.equals(String.withCString("I8")) || lane.equals(String.withCString("U8")))
            return String.withCString("i8x16");
        if (lane.equals(String.withCString("I16")) || lane.equals(String.withCString("U16")))
            return String.withCString("i16x8");
        if (lane.equals(String.withCString("I32")) || lane.equals(String.withCString("U32")))
            return String.withCString("i32x4");
        if (lane.equals(String.withCString("F32"))) return String.withCString("f32x4");
        return (String*)0;
    }

    static bool memOrVoid(String* t)
    {
        return t == (String*)0 || t.equals(String.withCString("Mem"))
            || t.equals(String.withCString("Void"));
    }

    static bool is64Ty(String* t)
    {
        return t != (String*)0 && (t.equals(String.withCString("I64"))
                                || t.equals(String.withCString("U64")));
    }

    static bool isSignedTy(String* t)
    {
        return t != (String*)0 && (t.equals(String.withCString("I8"))
                                || t.equals(String.withCString("I16"))
                                || t.equals(String.withCString("I32"))
                                || t.equals(String.withCString("I64")));
    }

    // XTIRType.byteWidth: fixed-width leaves only; 0 for Ptr/Agg/Void/Mem.
    static u32 leafWidth(String* t)
    {
        if (t == (String*)0) return (u32)0;
        if (t.equals(String.withCString("I8"))  || t.equals(String.withCString("U8"))
         || t.equals(String.withCString("Bool"))) return (u32)1;
        if (t.equals(String.withCString("I16")) || t.equals(String.withCString("U16")))
            return (u32)2;
        if (t.equals(String.withCString("I32")) || t.equals(String.withCString("U32"))
         || t.equals(String.withCString("F32"))) return (u32)4;
        if (t.equals(String.withCString("I64")) || t.equals(String.withCString("U64"))
         || t.equals(String.withCString("F64"))) return (u32)8;
        return (u32)0;
    }

    // wasmFieldWidth: pointers are 4 here, aggregates their full size.
    u32 fieldWidth(String* t)
    {
        if (t == (String*)0) return (u32)0;
        if (Wasm32.isPtrTy(t)) return (u32)4;
        if (Wasm32.isAggTy(t)) return aggSize(layoutOf(t));
        return Wasm32.leafWidth(t);
    }

    u32 aggSize(IRLayout* lay)
    {
        if (lay == (IRLayout*)0) return (u32)0;
        u32 total = lay.size();
        for (u32 i = (u32)0; i < lay.fieldCount(); i = i + (u32)1) {
            u32 end = lay.offsetAt(i) + fieldWidth(lay.typeAt(i));
            if (end > total) total = end;
        }
        return total;
    }

    // The RECORDED offset (blewit #5): never re-derived.
    u32 fieldOffset(IRLayout* lay, u32 idx)
    {
        if (lay == (IRLayout*)0 || idx >= lay.fieldCount()) return aggSize(lay);
        return lay.offsetAt(idx);
    }

    // A value's wasm VALUE type; aggregates are their slot ADDRESS (i32).
    static String* valType(String* t)
    {
        if (t == (String*)0) return String.withCString("i32");
        if (t.equals(String.withCString("I64")) || t.equals(String.withCString("U64")))
            return String.withCString("i64");
        if (t.equals(String.withCString("F32"))) return String.withCString("f32");
        if (t.equals(String.withCString("F64"))) return String.withCString("f64");
        if (t.hasPrefix(String.withCString("Vec("))) return String.withCString("v128");
        return String.withCString("i32");
    }

    // Canonicalisation (spec §3.1: u8+u8 wraps).
    static String* canonSuffix(String* t)
    {
        if (t == (String*)0) return (String*)0;
        if (t.equals(String.withCString("I8")))
            return String.withCString("    i32.extend8_s\n");
        if (t.equals(String.withCString("I16")))
            return String.withCString("    i32.extend16_s\n");
        if (t.equals(String.withCString("U8")))
            return String.withCString("    i32.const 255\n    i32.and\n");
        if (t.equals(String.withCString("U16")))
            return String.withCString("    i32.const 65535\n    i32.and\n");
        if (t.equals(String.withCString("Bool")))
            return String.withCString("    i32.const 1\n    i32.and\n");
        return (String*)0;
    }

    // The pointee of `Ptr(T, window)` — first depth-0 comma ends it.
    static String* pointeeOf(String* t)
    {
        if (!Wasm32.isPtrTy(t)) return (String*)0;
        u32 depth = (u32)0;
        for (u32 i = (u32)4; i < t.byteLength(); i = i + (u32)1) {
            u8 c = t.byteAt(i);
            if (c == (u8)'(') depth = depth + (u32)1;
            else if (c == (u8)')') {
                if (depth == (u32)0) return t.substringBytes((u32)4, i - (u32)4);
                depth = depth - (u32)1;
            }
            else if (c == (u8)',' && depth == (u32)0) return t.substringBytes((u32)4, i - (u32)4);
        }
        return (String*)0;
    }

    // The layout an `Agg(N)` names, or null.
    IRLayout* layoutOf(String* t)
    {
        if (!Wasm32.isAggTy(t)) return (IRLayout*)0;
        u32 n = (u32)0;
        for (u32 i = (u32)4; i < t.byteLength(); i = i + (u32)1) {
            u8 c = t.byteAt(i);
            if (c == (u8)')') break;
            if (c < (u8)'0' || c > (u8)'9') return (IRLayout*)0;
            n = n * (u32)10 + (u32)(c - (u8)'0');
        }
        if (_m == (IRModule*)0 || n >= _m.layouts().count()) return (IRLayout*)0;
        return (IRLayout*)_m.layouts().get(n);
    }

    // An operand's type spelling: a use reads its value's, an immediate its own.
    static String* tyOfOp(IROperand* op)
    {
        if (op.kind() == (u8)OPK_USE)
            return op.val() == 0 ? (String*)0 : op.val().ty();
        return op.ty();
    }

    static u32 alignUp(u32 v, u32 a) { return (v + a - (u32)1) & ~(a - (u32)1); }

    IRSymbol* symbolNamed(String* n)
    {
        if (n == (String*)0) return (IRSymbol*)0;
        return (IRSymbol*)_symByName.get((Hashable*)n);
    }

    // ── Small formatting helpers ─────────────────────────────────────────

    // Escape bytes into a WAT data-segment string literal (\xx lowercase).
    static String* watStringLit(Array* bytes)
    {
        String* s = String.withCString("");
        string digits = "0123456789abcdef";
        for (u32 i = (u32)0; i < bytes.count(); i = i + (u32)1) {
            u32 c = ((Number*)bytes.get(i)).asU32() & (u32)$FF;
            if (c >= (u32)$20 && c < (u32)$7F && c != (u32)34 && c != (u32)92)
                s.appendByte((u8)c);
            else {
                s.appendByte((u8)92);
                s.appendByte(digits[(c >> 4) & (u32)$F]);
                s.appendByte(digits[c & (u32)$F]);
            }
        }
        return s;
    }

    // printf's %a for the double the 64 bits spell — macOS normalises
    // subnormals (leading digit 1, exponent below -1022), strips trailing
    // zero nibbles, and always signs the exponent.
    static String* hexFloat(u64 bits)
    {
        String* s = String.withCString("");
        if ((bits >> 63) != (u64)0) s.appendCString("-");
        u32 ef = (u32)((bits >> 52) & (u64)$7FF);
        u64 mant = bits & (u64)$FFFFFFFFFFFFF;
        if (ef == (u32)$7FF) {
            s.appendCString(mant == (u64)0 ? "inf" : "nan");
            return s;
        }
        if (ef == (u32)0 && mant == (u64)0) {
            s.appendCString("0x0p+0");
            return s;
        }
        i32 e;
        u64 frac;
        if (ef == (u32)0) {
            // Subnormal: normalise. value = mant * 2^-1074 = 1.frac * 2^(nb-1074).
            u32 nb = (u32)51;
            while (((mant >> nb) & (u64)1) == (u64)0) nb = nb - (u32)1;
            e = (i32)nb - (i32)1074;
            frac = (mant << ((u64)52 - (u64)nb)) & (u64)$FFFFFFFFFFFFF;
        } else {
            e = (i32)ef - (i32)1023;
            frac = mant;
        }
        s.appendCString("0x1");
        if (frac != (u64)0) {
            string digits = "0123456789abcdef";
            // 13 nibbles, high first, trailing zeros stripped.
            u32 last = (u32)0;
            for (u32 i = (u32)0; i < (u32)13; i = i + (u32)1)
                if (((frac >> ((u64)48 - (u64)4 * (u64)i)) & (u64)$F) != (u64)0) last = i;
            s.appendCString(".");
            for (u32 i = (u32)0; i <= last; i = i + (u32)1)
                s.appendByte(digits[(u32)((frac >> ((u64)48 - (u64)4 * (u64)i)) & (u64)$F)]);
        }
        s.appendCString("p");
        if (e >= (i32)0) s.appendCString("+");
        s.appendFormat("%ld", e);
        return s;
    }

    // (float) of the double the 64 bits spell, as float bits — round to
    // nearest, ties to even; overflow to inf, tiny to signed zero.
    static u32 dblToFltBits(u64 d)
    {
        u32 sign = (u32)(d >> 63) << 31;
        u32 ef = (u32)((d >> 52) & (u64)$7FF);
        u64 m = d & (u64)$FFFFFFFFFFFFF;
        if (ef == (u32)$7FF) {
            if (m == (u64)0) return sign | (u32)$7F800000;
            u32 fm = (u32)(m >> 29) & (u32)$3FFFFF;
            return sign | (u32)$7FC00000 | fm;
        }
        if (ef == (u32)0) return sign;      // double subnormal is far below float range
        i32 ue = (i32)ef - (i32)1023;
        if (ue >= (i32)128) return sign | (u32)$7F800000;
        if (ue >= (i32)-126) {
            u64 keep = m >> 29;
            u64 rest = m & (u64)$1FFFFFFF;
            u64 half = (u64)$10000000;
            if (rest > half || (rest == half && (keep & (u64)1) != (u64)0))
                keep = keep + (u64)1;
            if (keep == (u64)$800000) { keep = (u64)0; ue = ue + (i32)1; }
            if (ue >= (i32)128) return sign | (u32)$7F800000;
            return sign | ((u32)(ue + (i32)127) << 23) | (u32)keep;
        }
        // Float subnormal (or zero): significand with hidden bit, shifted.
        u64 sig = ((u64)1 << 52) | m;
        u32 sh = (u32)29 + (u32)((i32)-126 - ue);
        if (sh > (u32)63) return sign;
        u64 keep2 = sig >> sh;
        u64 rest2 = sig & (((u64)1 << sh) - (u64)1);
        u64 half2 = (u64)1 << (sh - (u32)1);
        if (rest2 > half2 || (rest2 == half2 && (keep2 & (u64)1) != (u64)0))
            keep2 = keep2 + (u64)1;
        return sign | (u32)keep2;
    }

    // The double the float bits spell, as double bits (exact).
    // IEEE-754 bits of an integer, as `(double)v` / `(float)v` would give —
    // round to nearest, ties to even, for magnitudes past the mantissa. Used
    // for an integer immediate that carries a float type (bug 131).
    static u64 dblBitsOfInt(i64 v)
    {
        if (v == (i64)0) return (u64)0;
        u64 sign = (u64)0;
        u64 mag;
        if (v < (i64)0) { sign = (u64)1 << (u64)63; mag = (u64)0 - (u64)v; } else { mag = (u64)v; }
        u32 msb = (u32)0;
        for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) if (((mag >> (u64)i) & (u64)1) != (u64)0) msb = i;
        u64 mant;
        if (msb <= (u32)52) {
            mant = (mag << (u64)((u32)52 - msb)) & (((u64)1 << (u64)52) - (u64)1);
        } else {
            u32 drop = msb - (u32)52;
            u64 kept = mag >> (u64)drop;
            u64 rem  = mag & (((u64)1 << (u64)drop) - (u64)1);
            u64 half = (u64)1 << (u64)(drop - (u32)1);
            if (rem > half || (rem == half && (kept & (u64)1) != (u64)0)) kept = kept + (u64)1;
            if ((kept >> (u64)53) != (u64)0) { kept = kept >> (u64)1; msb = msb + (u32)1; }
            mant = kept & (((u64)1 << (u64)52) - (u64)1);
        }
        return sign | ((u64)(msb + (u32)1023) << (u64)52) | mant;
    }

    static u32 fltBitsOfInt(i64 v)
    {
        if (v == (i64)0) return (u32)0;
        u32 sign = (u32)0;
        u64 mag;
        if (v < (i64)0) { sign = (u32)1 << (u32)31; mag = (u64)0 - (u64)v; } else { mag = (u64)v; }
        u32 msb = (u32)0;
        for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) if (((mag >> (u64)i) & (u64)1) != (u64)0) msb = i;
        u32 mant;
        if (msb <= (u32)23) {
            mant = (u32)(mag << (u64)((u32)23 - msb)) & (((u32)1 << (u32)23) - (u32)1);
        } else {
            u32 drop = msb - (u32)23;
            u64 kept = mag >> (u64)drop;
            u64 rem  = mag & (((u64)1 << (u64)drop) - (u64)1);
            u64 half = (u64)1 << (u64)(drop - (u32)1);
            if (rem > half || (rem == half && (kept & (u64)1) != (u64)0)) kept = kept + (u64)1;
            if ((kept >> (u64)24) != (u64)0) { kept = kept >> (u64)1; msb = msb + (u32)1; }
            mant = (u32)kept & (((u32)1 << (u32)23) - (u32)1);
        }
        return sign | ((msb + (u32)127) << (u32)23) | mant;
    }

    static u64 fltToDblBits(u32 f)
    {
        u64 sign = (u64)(f >> 31) << 63;
        u32 ef = (f >> 23) & (u32)$FF;
        u32 fm = f & (u32)$7FFFFF;
        if (ef == (u32)$FF)
            return sign | ((u64)$7FF << 52) | ((u64)fm << 29);
        if (ef == (u32)0) {
            if (fm == (u32)0) return sign;
            // Normalise the subnormal: value = fm * 2^-149.
            u32 nb = (u32)22;
            while (((fm >> nb) & (u32)1) == (u32)0) nb = nb - (u32)1;
            i32 e = (i32)nb - (i32)149 + (i32)1023;
            u64 mm = (((u64)fm << ((u64)52 - (u64)nb)) & (u64)$FFFFFFFFFFFFF);
            return sign | ((u64)e << 52) | mm;
        }
        i32 de = (i32)ef - (i32)127 + (i32)1023;
        return sign | ((u64)de << 52) | ((u64)fm << 29);
    }

    // 16 hex digits -> the u64 they spell.
    static u64 bitsOfHex(String* h)
    {
        u64 v = (u64)0;
        if (h == (String*)0) return v;
        for (u32 i = (u32)0; i < h.byteLength(); i = i + (u32)1) {
            u8 c = h.byteAt(i);
            u32 d = (u32)0;
            if (c >= (u8)'0' && c <= (u8)'9') d = (u32)(c - (u8)'0');
            else if (c >= (u8)'a' && c <= (u8)'f') d = (u32)(c - (u8)'a') + (u32)10;
            else if (c >= (u8)'A' && c <= (u8)'F') d = (u32)(c - (u8)'A') + (u32)10;
            else continue;
            v = (v << 4) | (u64)d;
        }
        return v;
    }

    // Bytewise <, matching NSString compare: over ASCII names.
    static bool strLt(String* a, String* b)
    {
        u32 n = a.byteLength() < b.byteLength() ? a.byteLength() : b.byteLength();
        for (u32 i = (u32)0; i < n; i = i + (u32)1) {
            u8 ca = a.byteAt(i);
            u8 cb = b.byteAt(i);
            if (ca < cb) return true;
            if (ca > cb) return false;
        }
        return a.byteLength() < b.byteLength();
    }

    static Array* sorted(Array* names)
    {
        Array* out = new Array();
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            out.add(names.get(i));
        for (u32 i = (u32)1; i < out.count(); i = i + (u32)1) {
            Object* cur = out.get(i);
            u32 j = i;
            while (j > (u32)0 && Wasm32.strLt((String*)cur, (String*)out.get(j - (u32)1))) {
                out.set(j, out.get(j - (u32)1));
                j = j - (u32)1;
            }
            out.set(j, cur);
        }
        return out;
    }

    // The instruction's operands minus the memory token.
    static Array* dataOps(IRInsn* n)
    {
        Array* r = new Array();
        for (u32 i = (u32)0; i < n.ops().count(); i = i + (u32)1) {
            IROperand* o = (IROperand*)n.ops().get(i);
            if (o.kind() == (u8)OPK_USE && o.val() != 0
                && o.val().ty() != (String*)0
                && o.val().ty().equals(String.withCString("Mem"))) continue;
            r.add((Object*)o);
        }
        return r;
    }

    // ── Module emission ──────────────────────────────────────────────────
    String* assembly(IRModule* mod)
    {
        _m = mod;
        _symByName = new Map();
        _symAddr = new Map();
        _constAddr = new Array();
        _dataSegs = new Array();
        _importSigs = new Map();
        _importNames = new Array();
        _importPkg = new Map();
        _fatalImport = false;
        _definedFns = new Map();
        _fnTableIndex = new Map();
        _fnTableOrder = new Array();
        _indirectKeys = new Array();
        _indirectNames = new Array();
        _newSuffixes = new Array();
        _needsARC = false;
        _needsAlloc = false;
        _needsHeapInfo = false;
        _libImage = new Array();
        _libRelocAddr = new Array();
        _libRelocIsFn = new Array();
        _libRelocVal = new Array();
        _getterNames = new Array();
        _getterOffs = new Array();
        _externAddrPkg = new Map();
        _externAddrOrder = new Array();
        _fixupAddrs = new Array();
        _fixupNames = new Array();
        // Data starts ABOVE 0x10000 (the RTTI `< 0x10000` class-id guard);
        // a LIBRARY's offsets are relative to __memory_base, so start at 0.
        _dataEnd = _emitLib ? (u32)0 : (u32)$10000;

        for (u32 i = (u32)0; i < mod.syms().count(); i = i + (u32)1) {
            IRSymbol* s = (IRSymbol*)mod.syms().get(i);
            if (_symByName.get((Hashable*)s.name()) == (Object*)0)
                _symByName.set((Hashable*)s.name(), (Object*)s);
        }

        for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
            defineFn(((IRFunc*)mod.funcs().get(f)).name());

        // Runtime prescan + the funcref table (app: index 0 reserved;
        // library: indices are relative to __table_base, 0-based).
        for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)mod.funcs().get(f);
            _fnTableIndex.set((Hashable*)fn.name(),
                              (Object*)Number.with(_fnTableOrder.count()
                                  + (_emitLib ? (u32)0 : (u32)1)));
            _fnTableOrder.add((Object*)fn.name());
        }
        prescanRuntime(mod);
        placeData(mod);
        collectImports(mod);

        // Function bodies first: they discover the call_indirect signatures.
        String* fnsOut = String.withCString("");
        for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1)
            emitFunction((IRFunc*)mod.funcs().get(f), fnsOut);
        if (_needsItab) emitItabHelper(fnsOut);
        if (_emitLib) emitLibStubs(fnsOut);
        else if (_needsAlloc) emitRuntime(fnsOut);
        if (_emitLib) emitLibTail(fnsOut, mod);
        if (_linkLibs && _fixupAddrs.count() > (u32)0) emitAppFixup(fnsOut);

        String* out = String.withCString("");
        if (_emitLib) {
            out.appendFormat(";; module %s — generated by xcc-cg-wasm32 --emit-lib\n",
                             _m.name() == 0 ? "?" : _m.name().cString());
            out.appendFormat(";; xtc-lib data=%lu table=%lu\n",
                             _dataEnd, _fnTableOrder.count());
            out.appendCString("(module\n");
            emitLibHeader(out);
            out.append(fnsOut);
            out.appendCString(")\n");
            return out;
        }
        out.appendFormat(";; module %s — generated by xcc-cg-wasm32\n",
                         _m.name() == 0 ? "?" : _m.name().cString());
        out.appendCString("(module\n");
        emitHeader(out);
        for (u32 i = (u32)0; i < _dataSegs.count(); i = i + (u32)1)
            out.append((String*)_dataSegs.get(i));
        out.append(fnsOut);
        emitMainExport(mod, out);
        out.appendCString(")\n");
        return out;
    }

    // ── emit-lib module header (relocatable, dylink-shaped) ──────────────
    void emitLibHeader(String* out)
    {
        out.appendCString("  (import \"env\" \"memory\" (memory 0))\n");
        out.appendCString(
            "  (import \"env\" \"__indirect_function_table\" (table 0 funcref))\n");
        out.appendCString("  (import \"env\" \"__memory_base\" (global $__memory_base i32))\n");
        out.appendCString("  (import \"env\" \"__table_base\" (global $__table_base i32))\n");
        out.appendCString("  (import \"env\" \"__sp\" (global $__sp (mut i32)))\n");
        out.appendCString("  (import \"env\" \"__stack_low\" (global $__stack_low (mut i32)))\n");
        Array* impNames = Wasm32.sorted(_importNames);
        for (u32 i = (u32)0; i < impNames.count(); i = i + (u32)1) {
            String* name = (String*)impNames.get(i);
            String* pkg = (String*)_importPkg.get((Hashable*)name);
            out.appendFormat("  (import \"%s\" \"%s\" (func $%s %s))\n",
                             pkg == 0 ? "env" : pkg.cString(), name.cString(),
                             name.cString(),
                             ((String*)_importSigs.get((Hashable*)name)).cString());
        }
        if (_fnTableOrder.count() > (u32)0) {
            out.appendCString("  (elem (global.get $__table_base)");
            for (u32 i = (u32)0; i < _fnTableOrder.count(); i = i + (u32)1)
                out.appendFormat(" $%s", ((String*)_fnTableOrder.get(i)).cString());
            out.appendCString(")\n");
        }
        Array* sigKeys = Wasm32.sorted(_indirectKeys);
        for (u32 i = (u32)0; i < sigKeys.count(); i = i + (u32)1) {
            String* sig = (String*)sigKeys.get(i);
            out.appendFormat("  (type $%s (func %s))\n",
                             indirectNameFor(sig).cString(), sig.cString());
        }
        // The ONE data segment: every symbol at its relative offset inside
        // the payload, placed at __memory_base. Reloc words ride as zero.
        if (_libImage.count() > (u32)0) {
            while (_libImage.count() < _dataEnd)
                _libImage.add((Object*)Number.with((u32)0));
            while (_libImage.count() > _dataEnd)
                _libImage.removeAt(_libImage.count() - (u32)1);
            out.appendFormat("  (data (global.get $__memory_base) \"%s\")\n",
                             Wasm32.watStringLit(_libImage).cString());
        }
    }

    // emit-lib: write bytes into the single relative image at `at`.
    void libPlace(Array* bytes, u32 at)
    {
        while (_libImage.count() < at + bytes.count())
            _libImage.add((Object*)Number.with((u32)0));
        for (u32 i = (u32)0; i < bytes.count(); i = i + (u32)1)
            _libImage.set(at + i, bytes.get(i));
    }

    void prescanRuntime(IRModule* mod)
    {
        bool needsCount = false;
        for (u32 i = (u32)0; i < mod.syms().count(); i = i + (u32)1) {
            IRSymbol* sym = (IRSymbol*)mod.syms().get(i);
            if (sym.kind() != (u8)SYM_RUNTIME) continue;
            if (sym.name().equals(String.withCString("_xtc_alloc"))) _needsAlloc = true;
            else if (sym.name().equals(String.withCString("_xtc_count"))) {
                _needsAlloc = true;
                needsCount = true;
            }
            else if (sym.name().hasPrefix(String.withCString("_xtc_new_"))) {
                _needsAlloc = true;
                addSuffix(sym.name().substringBytes((u32)9, sym.name().byteLength() - (u32)9));
            }
        }
        for (u32 i = (u32)0; i < mod.syms().count(); i = i + (u32)1) {
            IRSymbol* sym = (IRSymbol*)mod.syms().get(i);
            if (sym.kind() != (u8)SYM_FUNCTION) continue;
            if (sym.name().equals(String.withCString("_xtc_heap_free_bytes"))
             || sym.name().equals(String.withCString("_xtc_heap_total_bytes"))
             || sym.name().equals(String.withCString("_xtc_heap_largest"))) {
                _needsHeapInfo = true;
                _needsAlloc = true;
            }
        }
        if (needsCount) addSuffix(String.withCString("__count__"));
        _needsWeakReg = false;
        _needsWeakUnreg = false;
        _needsItab = false;
        for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)mod.funcs().get(f);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) {
                    String* op = ((IRInsn*)bb.insns().get(i)).op();
                    if (op.equals(String.withCString("Retain"))
                     || op.equals(String.withCString("Release"))
                     || op.equals(String.withCString("Autorelease"))) _needsARC = true;
                    else if (op.equals(String.withCString("WeakRegister"))) _needsWeakReg = true;
                    else if (op.equals(String.withCString("WeakUnregister"))) _needsWeakUnreg = true;
                    else if (op.equals(String.withCString("ProtoDispatch"))
                          || op.equals(String.withCString("ProtoLoad"))) _needsItab = true;
                }
            }
        }
        if (_needsARC) _needsAlloc = true;
        // An app that links libraries carries the ONE runtime for every
        // module — emit and export the whole family (decision 3).
        if (_linkLibs) {
            _needsAlloc = true;
            _needsHeapInfo = true;
            addSuffix(String.withCString("__count__"));
        }
        if (_emitLib) {
            // A library defines only its per-type allocator STUBS; the rest
            // of the runtime family resolves as env imports.
            for (u32 i = (u32)0; i < _newSuffixes.count(); i = i + (u32)1) {
                String* suffix = (String*)_newSuffixes.get(i);
                if (suffix.equals(String.withCString("__count__"))) continue;
                String* n = String.withCString("_xtc_new_");
                n.append(suffix);
                defineFn(n);
            }
        } else if (_needsAlloc) {
            defineFn(String.withCString("_xtc_alloc"));
            defineFn(String.withCString("_xtc_dealloc"));
            defineFn(String.withCString("_xtc_count"));
            defineFn(String.withCString("_xtc_weak_register"));
            defineFn(String.withCString("_xtc_weak_unregister"));
            defineFn(String.withCString("_xtc_weak_load"));
            if (_needsHeapInfo) {
                defineFn(String.withCString("_xtc_heap_free_bytes"));
                defineFn(String.withCString("_xtc_heap_total_bytes"));
                defineFn(String.withCString("_xtc_heap_largest"));
            }
            for (u32 i = (u32)0; i < _newSuffixes.count(); i = i + (u32)1) {
                String* suffix = (String*)_newSuffixes.get(i);
                if (suffix.equals(String.withCString("__count__"))) continue;
                String* n = String.withCString("_xtc_new_");
                n.append(suffix);
                defineFn(n);
            }
        }
    }

    // Imports, memory, globals, the funcref table, the declared functypes.
    void emitHeader(String* out)
    {
        Array* impNames = Wasm32.sorted(_importNames);
        for (u32 i = (u32)0; i < impNames.count(); i = i + (u32)1) {
            String* name = (String*)impNames.get(i);
            String* pkg = (String*)_importPkg.get((Hashable*)name);
            out.appendFormat("  (import \"%s\" \"%s\" (func $%s %s))\n",
                             pkg == 0 ? "env" : pkg.cString(), name.cString(),
                             name.cString(),
                             ((String*)_importSigs.get((Hashable*)name)).cString());
        }
        out.appendCString("  (memory (export \"memory\") 32)\n");
        u32 stackTop = (u32)1048576;
        u32 stackLow = Wasm32.alignUp(_dataEnd, (u32)16);
        if (_linkLibs) {
            // Export the surface the loader wires each library to; the
            // mutable $__stack_low is raised past the last library's data.
            out.appendFormat("  (global $__sp (export \"__sp\") (mut i32) (i32.const %lu))\n",
                             stackTop);
            out.appendFormat("  (global $__stack_low (export \"__stack_low\") (mut i32) "
                             "(i32.const %lu))\n", stackLow);
            out.appendFormat("  (global $__data_end (export \"__data_end\") i32 "
                             "(i32.const %lu))\n", _dataEnd);
        } else {
            out.appendFormat("  (global $__sp (mut i32) (i32.const %lu))\n", stackTop);
            out.appendFormat("  (global $__stack_low i32 (i32.const %lu))\n", stackLow);
        }
        if (_needsAlloc) {
            out.appendFormat("  (global $__heap (mut i32) (i32.const %lu))\n", (u32)1048576);
            out.appendCString("  (global $__free (mut i32) (i32.const 0))\n");
        }
        if (_fnTableOrder.count() > (u32)0) {
            if (_linkLibs)
                out.appendFormat("  (table (export \"__indirect_function_table\") "
                                 "%lu funcref)\n", _fnTableOrder.count() + (u32)1);
            else
                out.appendFormat("  (table %lu funcref)\n", _fnTableOrder.count() + (u32)1);
            out.appendCString("  (elem (i32.const 1)");
            for (u32 i = (u32)0; i < _fnTableOrder.count(); i = i + (u32)1)
                out.appendFormat(" $%s", ((String*)_fnTableOrder.get(i)).cString());
            out.appendCString(")\n");
        }
        Array* sigKeys = Wasm32.sorted(_indirectKeys);
        for (u32 i = (u32)0; i < sigKeys.count(); i = i + (u32)1) {
            String* sig = (String*)sigKeys.get(i);
            out.appendFormat("  (type $%s (func %s))\n",
                             indirectNameFor(sig).cString(), sig.cString());
        }
    }

    // The entry export: run the module inits, then main.
    void emitMainExport(IRModule* mod, String* out)
    {
        IRFunc* mainFn = (IRFunc*)0;
        for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)mod.funcs().get(f);
            if (fn.name().equals(String.withCString("main"))) { mainFn = fn; break; }
        }
        if (mainFn == 0) return;
        bool mainReturns = !Wasm32.memOrVoid(mainFn.ret())
                        && !Wasm32.isAggTy(mainFn.ret());
        out.appendCString("  (func (export \"main\") (result i32)\n");
        if (_linkLibs && _fixupAddrs.count() > (u32)0)
            out.appendCString("    call $__xtc_fixup_imports\n");
        for (u32 i = (u32)0; i < mod.modinits().count(); i = i + (u32)1)
            out.appendFormat("    call $%s\n",
                             ((String*)mod.modinits().get(i)).cString());
        // One zero per DECLARED parameter of main. This wrapper is exported
        // with NO parameters (the generated loader calls `exports.main()`), so
        // whatever main takes has to be supplied here — and it used to supply
        // nothing. `i32 main(i32 argc, u8** argv)` emitted `call $main` on an
        // empty stack and every host rejected the module before running an
        // instruction:
        //     not enough arguments on the stack for call (need 2, got 0)
        // One line of source is enough, so EVERY wasm32 build whose main takes
        // argc/argv was broken (blewit FINDINGS #18b, which read it as a
        // ten-argument-call limit because that is the shape it was found in).
        //
        // argc = 0, argv = NULL: a wasm module has no command line, and a
        // conforming program reads neither when argc is 0. A fake non-null
        // argv would let `argv[0]` return garbage instead of trapping.
        // The memory token is skipped, as the signature emitter skips it.
        for (u32 i = (u32)0; i < mainFn.params().count(); i = i + (u32)1) {
            String* pt = ((IRValue*)mainFn.params().get(i)).ty();
            if (pt != 0 && pt.equals(String.withCString("Mem"))) continue;
            out.appendFormat("    %s.const 0\n", Wasm32.valType(pt).cString());
        }
        out.appendCString("    call $main\n");
        if (!mainReturns) out.appendCString("    i32.const 0\n");
        else if (Wasm32.is64Ty(mainFn.ret())) out.appendCString("    i32.wrap_i64\n");
        out.appendCString("  )\n");
    }

    void defineFn(String* name)
    {
        if (_definedFns.get((Hashable*)name) == (Object*)0)
            _definedFns.set((Hashable*)name, (Object*)Number.with((u32)1));
    }

    bool isDefined(String* name)
    { return _definedFns.get((Hashable*)name) != (Object*)0; }

    void addSuffix(String* s)
    {
        for (u32 i = (u32)0; i < _newSuffixes.count(); i = i + (u32)1)
            if (((String*)_newSuffixes.get(i)).equals(s)) return;
        _newSuffixes.add((Object*)s);
    }

    bool hasSuffix(String* s)
    {
        for (u32 i = (u32)0; i < _newSuffixes.count(); i = i + (u32)1)
            if (((String*)_newSuffixes.get(i)).equals(s)) return true;
        return false;
    }

    // ── Data placement ───────────────────────────────────────────────────
    void placeData(IRModule* mod)
    {
        for (u32 i = (u32)0; i < mod.syms().count(); i = i + (u32)1) {
            IRSymbol* sym = (IRSymbol*)mod.syms().get(i);
            if (sym.kind() == (u8)SYM_STRINGLIT) {
                Array* bytes = new Array();
                Array* sb = sym.bytes();
                if (sb != 0)
                    for (u32 k = (u32)0; k < sb.count(); k = k + (u32)1)
                        bytes.add(sb.get(k));
                bytes.add((Object*)Number.with((u32)0));      // NUL-terminate
                _symAddr.set((Hashable*)sym.name(), (Object*)Number.with(_dataEnd));
                if (_emitLib) libPlace(bytes, _dataEnd);
                else {
                    String* seg = String.withCString("");
                    seg.appendFormat("  (data (i32.const %lu) \"%s\") ;; %s\n",
                                     _dataEnd, Wasm32.watStringLit(bytes).cString(),
                                     sym.name().cString());
                    _dataSegs.add((Object*)seg);
                }
                _dataEnd = Wasm32.alignUp(_dataEnd + bytes.count(), (u32)8);
            } else if (sym.kind() == (u8)SYM_DATAGLOBAL) {
                if (sym.isExtern()) {
                    // A library-owned global: its address arrives through the
                    // library's exported __addr_ getter (link-libs only).
                    if (_linkLibs) ensureAddrGetterImport(sym);
                    continue;
                }
                u32 size = fieldWidth(sym.globalTy());
                if (size == (u32)0) size = (u32)1;
                _symAddr.set((Hashable*)sym.name(), (Object*)Number.with(_dataEnd));
                Array* init = sym.bytes();
                if (init != 0 && init.count() > (u32)0) {
                    // An f32 slot narrows the abstract 8-byte double image.
                    if (sym.globalTy() != 0
                        && sym.globalTy().equals(String.withCString("F32"))
                        && init.count() == (u32)8) {
                        u64 d = (u64)0;
                        for (u32 k = (u32)0; k < (u32)8; k = k + (u32)1)
                            d = d | ((u64)(((Number*)init.get(k)).asU32() & (u32)$FF)
                                     << ((u64)8 * (u64)k));
                        u32 fb = Wasm32.dblToFltBits(d);
                        Array* nb = new Array();
                        for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                            nb.add((Object*)Number.with((fb >> (k * (u32)8)) & (u32)$FF));
                        init = nb;
                    }
                    if (_emitLib) libPlace(init, _dataEnd);
                    else {
                        String* seg = String.withCString("");
                        seg.appendFormat("  (data (i32.const %lu) \"%s\") ;; %s\n",
                                         _dataEnd, Wasm32.watStringLit(init).cString(),
                                         sym.name().cString());
                        _dataSegs.add((Object*)seg);
                    }
                }
                if (!_emitLib && sym.attr(String.withCString("exported"))) {
                    String* seg = String.withCString("");
                    u32 addr = ((Number*)_symAddr.get((Hashable*)sym.name())).asU32();
                    seg.appendFormat("  (global $__exp_%s (export \"%s\") i32 (i32.const %lu))\n",
                                     sym.name().cString(), sym.name().cString(), addr);
                    _dataSegs.add((Object*)seg);
                }
                if (_emitLib) {
                    _getterNames.add((Object*)sym.name());
                    _getterOffs.add((Object*)Number.with(
                        ((Number*)_symAddr.get((Hashable*)sym.name())).asU32()));
                }
                _dataEnd = Wasm32.alignUp(_dataEnd + size, (u32)8);
            }
        }
        // Vtables: TWO passes — addresses first, words second.
        for (u32 i = (u32)0; i < mod.syms().count(); i = i + (u32)1) {
            IRSymbol* sym = (IRSymbol*)mod.syms().get(i);
            if (sym.kind() != (u8)SYM_VTABLE) continue;
            if (sym.isExtern()) {
                // An imported class's vtable lives IN ITS LIBRARY (the RTTI
                // downcast compares vtable ADDRESSES); reach it through the
                // library's __addr_ getter. A library imports the getter on
                // first reference instead.
                if (_linkLibs) ensureAddrGetterImport(sym);
                continue;
            }
            _symAddr.set((Hashable*)sym.name(), (Object*)Number.with(_dataEnd));
            if (_emitLib) {
                _getterNames.add((Object*)sym.name());
                _getterOffs.add((Object*)Number.with(_dataEnd));
            }
            u32 n = sym.slots() == 0 ? (u32)0 : sym.slots().count();
            _dataEnd = Wasm32.alignUp(_dataEnd + n * (u32)4, (u32)8);
        }
        for (u32 i = (u32)0; i < mod.syms().count(); i = i + (u32)1) {
            IRSymbol* sym = (IRSymbol*)mod.syms().get(i);
            if (sym.kind() != (u8)SYM_VTABLE) continue;
            if (sym.isExtern()) continue;
            Array* entries = sym.slots() == 0 ? new Array() : sym.slots();
            Array* words = new Array();
            u32 vbase = ((Number*)_symAddr.get((Hashable*)sym.name())).asU32();
            for (u32 k = (u32)0; k < entries.count(); k = k + (u32)1) {
                String* e = (String*)entries.get(k);
                u32 w = (u32)0;
                if (e.byteLength() == (u32)0 || e.equals(String.withCString("_"))) w = (u32)0;
                else if (e.hasPrefix(String.withCString("__protoid_"))) {
                    for (u32 c = (u32)10; c < e.byteLength(); c = c + (u32)1) {
                        u8 ch = e.byteAt(c);
                        if (ch < (u8)'0' || ch > (u8)'9') break;
                        w = w * (u32)10 + (u32)(ch - (u8)'0');
                    }
                } else {
                    Number* idx = (Number*)_fnTableIndex.get((Hashable*)e);
                    if (idx != 0) {
                        if (_emitLib) {
                            // A library's index words cannot be computed by a
                            // data segment — zero + __wasm_apply_relocs.
                            w = (u32)0;
                            _libRelocAddr.add((Object*)Number.with(vbase + k * (u32)4));
                            _libRelocIsFn.add((Object*)Number.with((u32)1));
                            _libRelocVal.add((Object*)idx);
                        } else w = idx.asU32();
                    } else {
                        Number* addr = (Number*)_symAddr.get((Hashable*)e);
                        if (addr != 0) {
                            if (_emitLib) {
                                w = (u32)0;
                                _libRelocAddr.add((Object*)Number.with(vbase + k * (u32)4));
                                _libRelocIsFn.add((Object*)Number.with((u32)0));
                                _libRelocVal.add((Object*)addr);
                            } else w = addr.asU32();
                        } else {
                            // A word naming ANOTHER module's symbol: an
                            // imported method takes a slot in this module's
                            // own table; another library's data comes from
                            // its __addr_ getter (an app patches the word in
                            // __xtc_fixup_imports, a library in
                            // __wasm_apply_relocs).
                            IRSymbol* ext = symbolNamed(e);
                            if ((_linkLibs || _emitLib) && ext != 0 && ext.isFunc()) {
                                u32 slot = ensureImportedFnSlot(ext);
                                if (_emitLib) {
                                    w = (u32)0;
                                    _libRelocAddr.add((Object*)Number.with(vbase + k * (u32)4));
                                    _libRelocIsFn.add((Object*)Number.with((u32)1));
                                    _libRelocVal.add((Object*)Number.with(slot));
                                } else w = slot;
                            } else if ((_linkLibs || _emitLib) && ext != 0 && ext.isExtern()
                                       && (ext.kind() == (u8)SYM_VTABLE
                                           || ext.kind() == (u8)SYM_DATAGLOBAL)) {
                                ensureAddrGetterImport(ext);
                                w = (u32)0;
                                if (_emitLib) {
                                    _libRelocAddr.add((Object*)Number.with(vbase + k * (u32)4));
                                    _libRelocIsFn.add((Object*)Number.with((u32)2));
                                    _libRelocVal.add((Object*)e);
                                } else {
                                    _fixupAddrs.add((Object*)Number.with(vbase + k * (u32)4));
                                    _fixupNames.add((Object*)e);
                                }
                            } else w = (u32)0;        // unresolved: TODO note only
                        }
                    }
                }
                words.add((Object*)Number.with(w & (u32)$FF));
                words.add((Object*)Number.with((w >> 8) & (u32)$FF));
                words.add((Object*)Number.with((w >> 16) & (u32)$FF));
                words.add((Object*)Number.with((w >> 24) & (u32)$FF));
            }
            if (_emitLib) libPlace(words, vbase);
            else {
                String* seg = String.withCString("");
                seg.appendFormat("  (data (i32.const %lu) \"%s\") ;; %s\n",
                                 vbase, Wasm32.watStringLit(words).cString(),
                                 sym.name().cString());
                _dataSegs.add((Object*)seg);
            }
        }
        // Constant-pool entries (string-kind byte images through the boundary).
        for (u32 i = (u32)0; i < mod.consts().count(); i = i + (u32)1) {
            Array* bytes = (Array*)mod.consts().get(i);
            while (_constAddr.count() <= i) _constAddr.add((Object*)0);
            if (bytes == 0 || bytes.count() == (u32)0) continue;
            _constAddr.set(i, (Object*)Number.with(_dataEnd));
            if (_emitLib) libPlace(bytes, _dataEnd);
            else {
                String* seg = String.withCString("");
                seg.appendFormat("  (data (i32.const %lu) \"%s\") ;; const %lu\n",
                                 _dataEnd, Wasm32.watStringLit(bytes).cString(), i);
                _dataSegs.add((Object*)seg);
            }
            _dataEnd = Wasm32.alignUp(_dataEnd + bytes.count(), (u32)8);
        }
    }

    // ── W2 helpers (twins of ensureImportedFnSlot / ensureAddrGetterImport /
    //    signatureFromShell / packageOfSymbol) ─────────────────────────────

    // The package a library-owned symbol rides in (pkg_<X> attribute).
    String* packageOf(IRSymbol* sym)
    {
        Array* keys = sym.extraAttrKeys();
        for (u32 k = (u32)0; k < keys.count(); k = k + (u32)1) {
            String* key = (String*)keys.get(k);
            if (key.hasPrefix(String.withCString("pkg_")) && sym.extraAttrVal(k))
                return key.substringBytes((u32)4, key.byteLength() - (u32)4);
        }
        return String.withCString("env");
    }

    // task #34: a C-variadic import has no single wasm functype (the type
    // was derived from the FIRST call site; other arities left operands on
    // the stack), and wasm32 has no C library to satisfy it anyway.
    void rejectVariadicImport(IRSymbol* sym)
    {
        Stdio.printf("xcc-cg-wasm32: error: '%s' is a C-variadic import — its call sites have no single wasm type, and wasm32 has no C library to satisfy it. Use Stdio.printf, or a fixed-arity #package import.\n",
                     sym.name().cString());
        _fatalImport = true;
    }

    // task #31: the spelled export/import label, when overload mangling
    // renamed the symbol — an expname_<name> attribute key; 0 when absent.
    String* exportNameOf(IRSymbol* sym)
    {
        Array* keys = sym.extraAttrKeys();
        for (u32 k = (u32)0; k < keys.count(); k = k + (u32)1) {
            String* key = (String*)keys.get(k);
            if (key.hasPrefix(String.withCString("expname_")) && sym.extraAttrVal(k))
                return key.substringBytes((u32)8, key.byteLength() - (u32)8);
        }
        return (String*)0;
    }

    // The import signature of a bodyless external's declared signature —
    // `(T, T) -> R` in the IR text. Paren-depth-aware split (Ptr(U8, ...)
    // carries commas), Mem skipped, an Agg return becomes a leading sret.
    String* signatureFromShellSig(String* sig)
    {
        String* params = String.withCString("");
        String* ret = String.withCString("Void");
        if (sig != 0) {
            u32 depth = (u32)0;
            u32 i = (u32)0;
            u32 n = sig.byteLength();
            // between the outer parens, split on top-level ", "
            if (n > (u32)0 && sig.byteAt((u32)0) == (u8)'(') {
                u32 start = (u32)1;
                i = (u32)1;
                depth = (u32)1;
                while (i < n && depth > (u32)0) {
                    u8 c = sig.byteAt(i);
                    if (c == (u8)'(') depth = depth + (u32)1;
                    else if (c == (u8)')') {
                        depth = depth - (u32)1;
                        if (depth == (u32)0) {
                            if (i > start)
                                params = shellParamsFrom(sig.substringBytes(start, i - start));
                        }
                    } else if (c == (u8)',' && depth == (u32)1) {
                        // handled inside shellParamsFrom — nothing here
                    }
                    i = i + (u32)1;
                }
                // ` -> R` follows the closing paren
                if (i + (u32)4 <= n)
                    ret = sig.substringBytes(i + (u32)4, n - i - (u32)4);
            }
        }
        String* out = String.withCString("");
        bool sret = ret.hasPrefix(String.withCString("Agg"))
                 || ret.hasPrefix(String.withCString("("));
        if (sret) out.appendCString("(param i32) ");
        out.append(params);
        if (!sret && !ret.equals(String.withCString("Void"))
            && !ret.equals(String.withCString("Mem")))
            out.appendFormat("(result %s)", Wasm32.valType(ret).cString());
        return out.trimmed();
    }

    // The `(param T) ` list for a comma-joined type list (depth-aware).
    String* shellParamsFrom(String* list)
    {
        String* out = String.withCString("");
        u32 depth = (u32)0;
        u32 start = (u32)0;
        u32 n = list.byteLength();
        for (u32 i = (u32)0; i <= n; i = i + (u32)1) {
            bool atEnd = i == n;
            u8 c = atEnd ? (u8)',' : list.byteAt(i);
            if (c == (u8)'(') depth = depth + (u32)1;
            else if (c == (u8)')') depth = depth - (u32)1;
            else if (c == (u8)',' && depth == (u32)0) {
                String* one = list.substringBytes(start, i - start).trimmed();
                if (one.byteLength() > (u32)0 && !one.equals(String.withCString("Mem"))
                    && !one.equals(String.withCString("...")))
                    out.appendFormat("(param %s) ", Wasm32.valType(one).cString());
                start = i + (u32)1;
            }
        }
        return out;
    }

    // link-libs: a slot in the app's own funcref table for an IMPORTED
    // function (dedup'd; registers the import from the declared signature
    // when no call site did). An --emit-lib module does the same for ANOTHER
    // library's function: the slot is in its own elem segment, relative to
    // __table_base like its local functions.
    u32 ensureImportedFnSlot(IRSymbol* sym)
    {
        Number* have = (Number*)_fnTableIndex.get((Hashable*)sym.name());
        if (have != 0) return have.asU32();
        if (_importSigs.get((Hashable*)sym.name()) == (Object*)0) {
            if (sym.variadic() && sym.cabi()) rejectVariadicImport(sym);
            _importSigs.set((Hashable*)sym.name(),
                            (Object*)signatureFromShellSig(sym.signature()));
            _importNames.add((Object*)sym.name());
            String* pkg = packageOf(sym);
            if (!pkg.equals(String.withCString("env")))
                _importPkg.set((Hashable*)sym.name(), (Object*)pkg);
        }
        u32 idx = _fnTableOrder.count() + (_emitLib ? (u32)0 : (u32)1); // app: 0 stays null
        _fnTableIndex.set((Hashable*)sym.name(), (Object*)Number.with(idx));
        _fnTableOrder.add((Object*)sym.name());
        return idx;
    }

    // link-libs: resolve an extern data symbol through an imported
    // `__addr_<name>` getter (first-reference order).
    void ensureAddrGetterImport(IRSymbol* sym)
    {
        if (_externAddrPkg.get((Hashable*)sym.name()) != (Object*)0) return;
        String* pkg = packageOf(sym);
        _externAddrPkg.set((Hashable*)sym.name(), (Object*)pkg);
        _externAddrOrder.add((Object*)sym.name());
        String* impName = String.withCString("__addr_");
        impName.append(sym.name());
        _importSigs.set((Hashable*)impName, (Object*)String.withCString("(result i32)"));
        _importNames.add((Object*)impName);
        if (!pkg.equals(String.withCString("env")))
            _importPkg.set((Hashable*)impName, (Object*)pkg);
    }

    // emit-lib: the per-type allocator stubs (the only locally defined
    // runtime — they bake table indices / element widths).
    void emitLibStubs(String* out)
    {
        Array* sfx = Wasm32.sorted(_newSuffixes);
        for (u32 i = (u32)0; i < sfx.count(); i = i + (u32)1) {
            String* suffix = (String*)sfx.get(i);
            if (suffix.equals(String.withCString("__count__"))) continue;
            u32 w = Wasm32.newWidth(suffix);
            if (w != (u32)0) {
                out.appendFormat(
                "  (func $_xtc_new_%s (export \"_xtc_new_%s\") (param $n i32) (result i32)\n",
                suffix.cString(), suffix.cString());
                out.appendFormat(
                "    local.get $n\n    i32.const %lu\n    i32.const 0\n    call $_xtc_alloc\n  )\n",
                w);
            } else {
                String* dn = String.withString(suffix);
                dn.appendCString("$dealloc");
                Number* de = (Number*)_fnTableIndex.get((Hashable*)dn);
                out.appendFormat(
                "  (func $_xtc_new_%s (export \"_xtc_new_%s\") (param $c i32) (param $s i32) (result i32)\n",
                suffix.cString(), suffix.cString());
                out.appendCString("    local.get $c\n    local.get $s\n");
                if (de != 0)
                    out.appendFormat(
                    "    global.get $__table_base\n    i32.const %lu\n    i32.add\n",
                    de.asU32());
                else
                    out.appendCString("    i32.const 0\n");
                out.appendCString("    call $_xtc_alloc\n  )\n");
            }
        }
    }

    // emit-lib: __addr_ getters + __wasm_apply_relocs (patches the words a
    // data segment cannot compute, then runs the module inits).
    void emitLibTail(String* out, IRModule* mod)
    {
        for (u32 i = (u32)0; i < _getterNames.count(); i = i + (u32)1) {
            String* gn = (String*)_getterNames.get(i);
            out.appendFormat(
            "  (func $__addr_%s (export \"__addr_%s\") (result i32)\n",
            gn.cString(), gn.cString());
            out.appendFormat(
            "    global.get $__memory_base\n    i32.const %lu\n    i32.add\n  )\n",
            ((Number*)_getterOffs.get(i)).asU32());
        }
        out.appendCString("  (func $__wasm_apply_relocs (export \"__wasm_apply_relocs\")\n");
        for (u32 i = (u32)0; i < _libRelocAddr.count(); i = i + (u32)1) {
            u32 kind = ((Number*)_libRelocIsFn.get(i)).asU32();
            if (kind == (u32)2) {
                // Another library's data address, from its __addr_ getter.
                out.appendFormat(
                "    global.get $__memory_base\n    i32.const %lu\n    i32.add\n"
                "    call $__addr_%s\n    i32.store\n",
                ((Number*)_libRelocAddr.get(i)).asU32(),
                ((String*)_libRelocVal.get(i)).cString());
                continue;
            }
            bool isFn = kind != (u32)0;
            out.appendFormat(
            "    global.get $__memory_base\n    i32.const %lu\n    i32.add\n",
            ((Number*)_libRelocAddr.get(i)).asU32());
            out.appendFormat(
            "    global.get $%s\n    i32.const %lu\n    i32.add\n"
            "    i32.store\n",
            isFn ? "__table_base" : "__memory_base",
            ((Number*)_libRelocVal.get(i)).asU32());
        }
        for (u32 i = (u32)0; i < mod.modinits().count(); i = i + (u32)1)
            out.appendFormat("    call $%s\n",
                             ((String*)mod.modinits().get(i)).cString());
        out.appendCString("  )\n");
    }

    // link-libs: patch the app's vtable words that hold LIBRARY data
    // addresses (runs from the exported main wrapper, before the inits).
    void emitAppFixup(String* out)
    {
        out.appendCString("  (func $__xtc_fixup_imports\n");
        for (u32 i = (u32)0; i < _fixupAddrs.count(); i = i + (u32)1) {
            out.appendFormat(
            "    i32.const %lu\n    call $__addr_%s\n    i32.store\n",
            ((Number*)_fixupAddrs.get(i)).asU32(),
            ((String*)_fixupNames.get(i)).cString());
        }
        out.appendCString("  )\n");
    }

    // ── Import signatures ────────────────────────────────────────────────
    String* signatureForCall(IRInsn* insn)
    {
        String* sig = String.withCString("");
        for (u32 i = (u32)1; i < insn.ops().count(); i = i + (u32)1) {
            IROperand* op = (IROperand*)insn.ops().get(i);
            String* t = Wasm32.tyOfOp(op);
            if (Wasm32.memOrVoid(t)) continue;
            sig.appendFormat("(param %s) ", Wasm32.valType(t).cString());
        }
        if (insn.res() != 0 && !Wasm32.memOrVoid(insn.res().ty()))
            sig.appendFormat("(result %s)", Wasm32.valType(insn.res().ty()).cString());
        return sig.trimmed();
    }

    String* indirectNameFor(String* key)
    {
        for (u32 i = (u32)0; i < _indirectKeys.count(); i = i + (u32)1)
            if (((String*)_indirectKeys.get(i)).equals(key))
                return (String*)_indirectNames.get(i);
        return (String*)0;
    }

    // Interned functype for an indirect-call site (sret first when the
    // result is an aggregate).
    String* indirectTypeFor(Array* argTys, String* resTy)
    {
        String* sig = String.withCString("");
        bool sret = resTy != (String*)0 && Wasm32.isAggTy(resTy);
        if (sret) sig.appendCString("(param i32) ");
        for (u32 i = (u32)0; i < argTys.count(); i = i + (u32)1)
            sig.appendFormat("(param %s) ", Wasm32.valType((String*)argTys.get(i)).cString());
        if (resTy != (String*)0 && !Wasm32.memOrVoid(resTy) && !sret)
            sig.appendFormat("(result %s)", Wasm32.valType(resTy).cString());
        String* key = sig.trimmed();
        String* name = indirectNameFor(key);
        if (name == (String*)0) {
            name = String.withCString("it");
            name.appendFormat("%lu", _indirectKeys.count());
            _indirectKeys.add((Object*)key);
            _indirectNames.add((Object*)name);
        }
        return name;
    }

    void collectImports(IRModule* mod)
    {
        for (u32 f = (u32)0; f < mod.funcs().count(); f = f + (u32)1) {
            IRFunc* fn = (IRFunc*)mod.funcs().get(f);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                u32 total = bb.insns().count() + (bb.term() != 0 ? (u32)1 : (u32)0);
                for (u32 i = (u32)0; i < total; i = i + (u32)1) {
                    IRInsn* insn = i < bb.insns().count()
                        ? (IRInsn*)bb.insns().get(i) : bb.term();
                    String* op = insn.op();
                    if (!op.equals(String.withCString("Call"))
                     && !op.equals(String.withCString("CallCloaked"))
                     && !op.equals(String.withCString("CallBanked"))) continue;
                    if (insn.ops().count() < (u32)1) continue;
                    IROperand* callee = (IROperand*)insn.ops().get((u32)0);
                    if (callee.kind() != (u8)OPK_SYM) continue;
                    IRSymbol* sym = symbolNamed(callee.name());
                    if (sym == 0 || isDefined(sym.name())) continue;
                    if (sym.kind() != (u8)SYM_FUNCTION
                     && sym.kind() != (u8)SYM_RUNTIME) continue;
                    if (_importSigs.get((Hashable*)sym.name()) == (Object*)0) {
                        if (sym.variadic() && sym.cabi()) rejectVariadicImport(sym);
                        _importSigs.set((Hashable*)sym.name(),
                                        (Object*)signatureForCall(insn));
                        _importNames.add((Object*)sym.name());
                        Array* keys = sym.extraAttrKeys();
                        for (u32 k = (u32)0; k < keys.count(); k = k + (u32)1) {
                            String* key = (String*)keys.get(k);
                            if (key.hasPrefix(String.withCString("pkg_"))
                                && sym.extraAttrVal(k)) {
                                _importPkg.set((Hashable*)sym.name(),
                                    (Object*)key.substringBytes((u32)4, key.byteLength() - (u32)4));
                                break;
                            }
                        }
                    }
                }
            }
        }
        // A library reaches the APP's runtime through env imports: the
        // direct-`call` families (ARC, weak, the stubs' _xtc_alloc) have no
        // Call insn to derive from — declare their fixed shapes here.
        if (_emitLib) {
            if (_needsARC) {
                libImport(String.withCString("__xtc_retain"),
                          String.withCString("(param i32)"));
                libImport(String.withCString("__xtc_release"),
                          String.withCString("(param i32)"));
            }
            if (_needsWeakReg)
                libImport(String.withCString("_xtc_weak_register"),
                          String.withCString("(param i32) (param i32)"));
            if (_needsWeakUnreg)
                libImport(String.withCString("_xtc_weak_unregister"),
                          String.withCString("(param i32)"));
            if (_needsAlloc)
                libImport(String.withCString("_xtc_alloc"),
                          String.withCString("(param i32) (param i32) (param i32) (result i32)"));
        }
    }

    // Register (or overwrite with the fixed shape) an emit-lib runtime import.
    void libImport(String* name, String* sig)
    {
        if (_importSigs.get((Hashable*)name) == (Object*)0)
            _importNames.add((Object*)name);
        _importSigs.set((Hashable*)name, (Object*)sig);
    }

    // ── Function emission ────────────────────────────────────────────────
    void emitFunction(IRFunc* fn, String* out)
    {
        WasmFnCtx* ctx = new WasmFnCtx();
        ctx._fn = fn;
        u32 nIds = fn.byId().count();
        ctx.sizeTo(nIds);
        ctx._hasSret = Wasm32.isAggTy(fn.ret());

        // Local-name map (-O1+): the rank of every value id that appears in
        // the FINAL body (params included), ascending. Dead registered
        // values (id gaps) get no local, no slot, no name.
        dropRank();
        Array* orderedIds = (Array*)0;
        if (_optLevel >= (u32)1) {
            u32 m0 = nIds == (u32)0 ? (u32)1 : nIds;
            bool* seen = new bool[m0];
            for (u32 i = (u32)0; i < m0; i = i + (u32)1) seen[i] = false;
            for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
                if (i < nIds) seen[i] = true;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1) {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                markSeen(seen, nIds, bb.phis());
                markSeen(seen, nIds, bb.insns());
                if (bb.term() != 0) markSeenOne(seen, nIds, bb.term());
            }
            orderedIds = new Array();
            _vRank = new u32[m0];
            _vRankN = nIds;
            for (u32 i = (u32)0; i < m0; i = i + (u32)1) _vRank[i] = (u32)$FFFFFFFF;
            u32 r = (u32)0;
            for (u32 i = (u32)0; i < nIds; i = i + (u32)1) {
                if (!seen[i]) continue;
                _vRank[i] = r;
                r = r + (u32)1;
                orderedIds.add((Object*)Number.with(i));
            }
            delete seen;
        }

        // Pinned locals RE-LAID at wasm widths, then one slot per Agg value.
        u32 frame = (u32)0;
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1) {
            IRPinned* pl = (IRPinned*)fn.pinned().get(i);
            u32 w = fieldWidth(pl.ty());
            if (w == (u32)0) w = (u32)4;
            u32 a = w >= (u32)8 ? (u32)8 : (w >= (u32)4 ? (u32)4 : (w >= (u32)2 ? (u32)2 : (u32)1));
            frame = Wasm32.alignUp(frame, a);
            u32 vid = pl.val().pid();
            if (vid < nIds) {
                if (ctx._pinnedOff[vid] == (u32)$FFFFFFFF)
                    ctx._pinnedKeys.add((Object*)Number.with(vid));
                ctx._pinnedOff[vid] = frame;
            }
            frame = frame + w;
        }
        frame = Wasm32.alignUp(frame, (u32)8);
        // -O1+: only ids in the final body get slots (orderedIds, ascending);
        // -O0: every registered id, exactly as before.
        u32 slotIdCount = orderedIds != 0 ? orderedIds.count() : nIds;
        for (u32 si = (u32)0; si < slotIdCount; si = si + (u32)1) {
            u32 vid = orderedIds != 0 ? ((Number*)orderedIds.get(si)).asU32() : si;
            IRValue* v = fn.valueWithId(vid);
            if (v == 0 || !Wasm32.isAggTy(v.ty())) continue;
            if (ctx._pinnedOff[vid] != (u32)$FFFFFFFF) continue;
            if (vid < fn.params().count()) continue;    // params arrive as an address
            ctx._aggSlot[vid] = frame;
            ctx._aggKeys.add((Object*)Number.with(vid));
            frame = Wasm32.alignUp(frame + aggSize(layoutOf(v.ty())), (u32)8);
        }
        ctx._frameSize = Wasm32.alignUp(frame, (u32)16);

        // Signature. Params ARE locals 0..n-1; Mem gets no wasm param.
        // --emit-lib: every defined function IS the public surface.
        IRSymbol* fnSym = symbolNamed(fn.name());
        bool exported = _emitLib
                     || (fnSym != 0 && fnSym.attr(String.withCString("exported")));
        out.appendFormat("  (func $%s", fn.name().cString());
        if (exported) {
            String* lbl = fnSym == 0 ? (String*)0 : exportNameOf(fnSym);
            out.appendFormat(" (export \"%s\")",
                             (lbl == 0 ? fn.name() : lbl).cString());
        }
        if (ctx._hasSret) out.appendCString(" (param $sret i32)");
        u32 nParams = fn.params().count();
        for (u32 i = (u32)0; i < nParams; i = i + (u32)1) {
            String* pt = ((IRValue*)fn.params().get(i)).ty();
            if (pt != 0 && pt.equals(String.withCString("Mem"))) continue;
            out.appendFormat(" (param $v%lu %s)", vnum(i), Wasm32.valType(pt).cString());
            if (i < nIds) ctx._declared[i] = true;
        }
        bool scalarRet = !Wasm32.memOrVoid(fn.ret()) && !Wasm32.isAggTy(fn.ret());
        if (scalarRet) out.appendFormat(" (result %s)", Wasm32.valType(fn.ret()).cString());
        out.appendCString("\n");

        // Control-flow mode. -O0 (and any function the plan rejects) keeps
        // the bring-up dispatch loop — the wasm-diff oracle form, byte for
        // byte. -O1+ emits real nested block/loop/if from the dominator
        // tree; $pc exists only in dispatch mode.
        WasmCFGPlan* plan = (WasmCFGPlan*)0;
        if (_optLevel >= (u32)1) plan = structurePlan(fn);

        // Locals: $pc (dispatch mode only) + $fp + one per remaining value id.
        if (plan != 0) out.appendCString("    (local $fp i32)\n");
        else           out.appendCString("    (local $pc i32) (local $fp i32)\n");
        u32 declIdCount = orderedIds != 0 ? orderedIds.count() : nIds;
        for (u32 di = (u32)0; di < declIdCount; di = di + (u32)1) {
            u32 vid = orderedIds != 0 ? ((Number*)orderedIds.get(di)).asU32() : di;
            if (ctx._declared[vid]) continue;
            IRValue* v = fn.valueWithId(vid);
            if (v == 0 || Wasm32.memOrVoid(v.ty())) continue;
            // A PINNED local (one whose address is taken) holds its frame
            // ADDRESS, not its value — the prologue below seeds it with
            // `$fp + off`. Its declared type must therefore be i32 whatever
            // the value's type is. Declaring it from the value type was
            // invisible while every pinned local was 32 bits or narrower, but
            // `u64 v; u64@ p = &v;` declared an i64 local and then local.set an
            // i32 address into it — a module the engine rejects outright.
            bool holdsAddr = vid < nIds
                          && (ctx._pinnedOff[vid] != (u32)$FFFFFFFF
                           || ctx._aggSlot[vid]  != (u32)$FFFFFFFF);
            out.appendFormat("    (local $v%lu %s)\n", vnum(vid),
                             holdsAddr ? "i32" : Wasm32.valType(v.ty()).cString());
            ctx._declared[vid] = true;
        }

        // Prologue: push the shadow frame, trap on overflow, zero it, and
        // seed the address locals — in the ORIGINAL's dictionary order.
        if (ctx._frameSize != (u32)0) {
            out.appendFormat("    global.get $__sp\n    i32.const %lu\n    i32.sub\n", ctx._frameSize);
            out.appendCString("    local.tee $fp\n    global.get $__stack_low\n");
            out.appendCString("    i32.lt_u\n    if\n      unreachable\n    end\n");
            out.appendCString("    local.get $fp\n    global.set $__sp\n");
            out.appendFormat("    local.get $fp\n    i32.const 0\n    i32.const %lu\n", ctx._frameSize);
            out.appendCString("    memory.fill\n");
        } else {
            out.appendCString("    global.get $__sp\n    local.set $fp\n");
        }
        Array* pOrder = Wasm32.ascendingKeys(ctx._pinnedKeys);
        for (u32 i = (u32)0; i < pOrder.count(); i = i + (u32)1) {
            u32 vid = ((Number*)pOrder.get(i)).asU32();
            if (vid >= nIds || !ctx._declared[vid]) continue;
            out.appendFormat("    local.get $fp\n    i32.const %lu\n    i32.add\n",
                             ctx._pinnedOff[vid]);
            out.appendFormat("    local.set $v%lu\n", vnum(vid));
        }
        Array* aOrder = Wasm32.ascendingKeys(ctx._aggKeys);
        for (u32 i = (u32)0; i < aOrder.count(); i = i + (u32)1) {
            u32 vid = ((Number*)aOrder.get(i)).asU32();
            if (vid >= nIds || !ctx._declared[vid]) continue;
            out.appendFormat("    local.get $fp\n    i32.const %lu\n    i32.add\n",
                             ctx._aggSlot[vid]);
            out.appendFormat("    local.set $v%lu\n", vnum(vid));
        }

        // Structured mode: the dominator-tree walk from the entry. Every
        // path ends in return/unreachable/br; the trailing `unreachable`
        // only satisfies the validator (as it does after the dispatch loop).
        if (plan != 0) {
            emitStructuredTree((u32)0, plan, fn, ctx, out);
            out.appendCString("    unreachable\n  )\n");
            plan.dropSlots();
            ctx.dropSlots();
            dropRank();
            return;
        }

        // The dispatch loop: one arm per IR block, $pc selects.
        u32 n = fn.blocks().count();
        out.appendCString("    loop $dispatch\n");
        for (u32 i = n; i > (u32)0; i = i - (u32)1)
            out.appendFormat("    block $B%lu\n", i - (u32)1);
        out.appendCString("    local.get $pc\n    br_table");
        for (u32 i = (u32)0; i < n; i = i + (u32)1) out.appendFormat(" $B%lu", i);
        out.appendFormat(" $B%lu\n", n - (u32)1);
        for (u32 i = (u32)0; i < n; i = i + (u32)1) {
            IRBlock* b = (IRBlock*)fn.blocks().get(i);
            out.appendFormat("    end ;; $B%lu — %s\n", i,
                             b.name() == 0 ? "?" : b.name().cString());
            IRInsn* tail = tailCallableInsn(b, fn, ctx);
            for (u32 k = (u32)0; k < b.insns().count(); k = k + (u32)1) {
                IRInsn* one = (IRInsn*)b.insns().get(k);
                if (one == tail) continue;   // fused into return_call below
                emitInsn(one, fn, ctx, out);
            }
            if (tail != (IRInsn*)0) emitTailCall(tail, fn, ctx, out);
            else emitTerminator(b.term(), b, fn, ctx, out);
        }
        out.appendCString("    end ;; loop $dispatch\n    unreachable\n  )\n");
        ctx.dropSlots();
        dropRank();
    }

    // ── Operand loading ──────────────────────────────────────────────────
    // Push a branch or select condition as the i32 that `if` and `select`
    // take. An i64, f32 or f64 condition is tested against zero in its own
    // type: pushed as it was, it made a module that does not validate (bug
    // 293).
    void pushCondition(IROperand* op, String* out)
    {
        pushOperand(op, out);
        String* vt = Wasm32.valType(tyOfOp(op));
        if (vt.equals(String.withCString("i64")) || vt.equals(String.withCString("f32"))
         || vt.equals(String.withCString("f64")))
            out.appendFormat("    %s.const 0\n    %s.ne\n", vt.cString(), vt.cString());
    }

    void pushOperand(IROperand* op, String* out)
    {
        u8 k = op.kind();
        if (k == (u8)OPK_USE) {
            out.appendFormat("    local.get $v%lu\n", vnum(op.val() == 0 ? (u32)0 : op.val().pid()));
            return;
        }
        if (k == (u8)OPK_IMMI) {
            // An INTEGER immediate can carry a FLOAT type — `Const #0:F64` is
            // how a double zero is lowered — and it must become a float
            // constant, or the module is `i32.const 0` into an f64 local:
            // invalid, refused by every runtime at load (bug 131). Mirrors
            // the reference's `f64.const %a` of the value as a double.
            if (op.ty() != (String*)0 && op.ty().equals(String.withCString("F64"))) {
                out.appendFormat("    f64.const %s\n", Wasm32.hexFloat(Wasm32.dblBitsOfInt(op.imm())).cString());
                return;
            }
            if (op.ty() != (String*)0 && op.ty().equals(String.withCString("F32"))) {
                out.appendFormat("    f32.const %s\n", Wasm32.hexFloat(Wasm32.fltToDblBits(Wasm32.fltBitsOfInt(op.imm()))).cString());
                return;
            }
            if (Wasm32.is64Ty(op.ty()))
                out.appendFormat("    i64.const %s\n", String.withI64(op.imm()).cString());
            else
                out.appendFormat("    i32.const %ld\n", (i32)op.imm());
            return;
        }
        if (k == (u8)OPK_IMMF) {
            u64 bits = Wasm32.bitsOfHex(op.fpHex());
            if (op.ty() != 0 && op.ty().equals(String.withCString("F32"))) {
                u64 nb = Wasm32.fltToDblBits(Wasm32.dblToFltBits(bits));
                out.appendFormat("    f32.const %s\n", Wasm32.hexFloat(nb).cString());
            } else {
                out.appendFormat("    f64.const %s\n", Wasm32.hexFloat(bits).cString());
            }
            return;
        }
        if (k == (u8)OPK_SYM) {
            IRSymbol* sym = symbolNamed(op.name());
            Number* addr = sym == 0 ? (Number*)0 : (Number*)_symAddr.get((Hashable*)sym.name());
            Number* fnIdx = sym == 0 ? (Number*)0 : (Number*)_fnTableIndex.get((Hashable*)sym.name());
            if (addr != 0) {
                if (_emitLib)
                    out.appendFormat("    global.get $__memory_base\n"
                                     "    i32.const %lu\n    i32.add ;; &%s\n",
                                     addr.asU32(), sym.name().cString());
                else
                    out.appendFormat("    i32.const %lu ;; &%s\n",
                                     addr.asU32(), sym.name().cString());
            } else if (fnIdx != 0) {
                if (_emitLib)
                    out.appendFormat("    global.get $__table_base\n"
                                     "    i32.const %lu\n    i32.add ;; table:%s\n",
                                     fnIdx.asU32(), sym.name().cString());
                else
                    out.appendFormat("    i32.const %lu ;; table:%s\n",
                                     fnIdx.asU32(), sym.name().cString());
            } else if ((_linkLibs || _emitLib) && sym != 0 && sym.isExtern()
                       && (sym.kind() == (u8)SYM_VTABLE
                           || sym.kind() == (u8)SYM_DATAGLOBAL)) {
                ensureAddrGetterImport(sym);
                out.appendFormat("    call $__addr_%s ;; &%s (import)\n",
                                 sym.name().cString(), sym.name().cString());
            } else if ((_linkLibs || _emitLib) && sym != 0 && sym.isFunc()
                       && !isDefined(sym.name())) {
                u32 slot = ensureImportedFnSlot(sym);
                if (_emitLib)
                    out.appendFormat("    global.get $__table_base\n"
                                     "    i32.const %lu\n    i32.add ;; table:%s (import)\n",
                                     slot, sym.name().cString());
                else
                    out.appendFormat("    i32.const %lu ;; table:%s (import)\n",
                                     slot, sym.name().cString());
            } else
                out.appendCString("    i32.const 0\n");
            return;
        }
        if (k == (u8)OPK_CPOOL) {
            Number* addr = op.cid() < _constAddr.count()
                ? (Number*)_constAddr.get(op.cid()) : (Number*)0;
            if (_emitLib)
                out.appendFormat("    global.get $__memory_base\n"
                                 "    i32.const %lu\n    i32.add ;; const pool\n",
                                 addr == 0 ? (u32)0 : addr.asU32());
            else
                out.appendFormat("    i32.const %lu ;; const pool\n",
                                 addr == 0 ? (u32)0 : addr.asU32());
            return;
        }
        out.appendCString("    i32.const 0 ;; TODO operand kind\n");
    }

    void setResult(IRValue* res, bool canon, String* out)
    {
        if (res == 0 || Wasm32.memOrVoid(res.ty())) {
            out.appendCString("    drop\n");
            return;
        }
        if (canon) {
            String* c = Wasm32.canonSuffix(res.ty());
            if (c != 0) out.append(c);
        }
        out.appendFormat("    local.set $v%lu\n", vnum(res.pid()));
    }

    // A shift/rotate count must match the operation width.
    void widenCount(IROperand* count, String* p, String* out)
    {
        if (!p.equals(String.withCString("i64"))) return;
        if (!Wasm32.is64Ty(Wasm32.tyOfOp(count)))
            out.appendCString("    i64.extend_i32_u\n");
    }

    // ── Instructions ─────────────────────────────────────────────────────
    void emitInsn(IRInsn* insn, IRFunc* fn, WasmFnCtx* ctx, String* out)
    {
        String* op = insn.op();
        if (emitCore(insn, op, out)) return;
        if (emitShifts(insn, op, out)) return;
        if (emitCmpSel(insn, op, out)) return;
        if (emitFloat(insn, op, out)) return;
        if (emitCasts(insn, op, out)) return;
        if (emitMemoryOps(insn, op, out)) return;
        if (emitAggOps(insn, op, out)) return;
        if (emitCalls(insn, op, out)) return;
        if (emitArc(insn, op, out)) return;
        if (emitVector(insn, op, out)) return;
        // Unknown: placeholder, matching the original's default arm.
        IRValue* res = insn.res();
        if (res != 0 && !Wasm32.memOrVoid(res.ty())) {
            out.appendFormat("    %s.const 0\n", Wasm32.valType(res.ty()).cString());
            setResult(res, false, out);
        }
    }

    // ── SIMD (V* from the vectoriser) → wasm v128 ────────────────────────
    bool emitVector(IRInsn* insn, String* op, String* out)
    {
        if (op.byteLength() < (u32)2 || op.byteAt((u32)0) != (u8)'V') return false;
        IRValue* res = insn.res();
        Array* ops = Wasm32.dataOps(insn);

        if (op.equals(String.withCString("VLoad"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendCString("    v128.load\n");
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("VStore"))) {
            if (ops.count() < (u32)2) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            pushOperand((IROperand*)ops.get((u32)1), out);
            out.appendCString("    v128.store\n");
            return true;
        }
        if (op.equals(String.withCString("VSplat"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            String* shape = Wasm32.laneShape(Wasm32.laneOf(res.ty()));
            if (shape == (String*)0) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendFormat("    %s.splat\n", shape.cString());
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("VAdd")) || op.equals(String.withCString("VSub"))
         || op.equals(String.withCString("VMul")) || op.equals(String.withCString("VAnd"))
         || op.equals(String.withCString("VOr"))  || op.equals(String.withCString("VXor"))) {
            if (res == 0 || ops.count() < (u32)2) return true;
            bool bitwise = op.equals(String.withCString("VAnd"))
                        || op.equals(String.withCString("VOr"))
                        || op.equals(String.withCString("VXor"));
            String* lane = Wasm32.laneOf(res.ty());
            bool lane8 = lane != (String*)0 && (lane.equals(String.withCString("I8"))
                                             || lane.equals(String.withCString("U8")));
            if (op.equals(String.withCString("VMul")) && lane8) {
                // wasm has no i8x16.mul: widen both to i16x8 (low/high
                // halves), multiply there, and take each 16-bit product's
                // LOW byte back — exact wrapping u8*u8/i8*i8.
                pushOperand((IROperand*)ops.get((u32)0), out);
                out.appendCString("    i16x8.extend_low_i8x16_u\n");
                pushOperand((IROperand*)ops.get((u32)1), out);
                out.appendCString("    i16x8.extend_low_i8x16_u\n    i16x8.mul\n");
                pushOperand((IROperand*)ops.get((u32)0), out);
                out.appendCString("    i16x8.extend_high_i8x16_u\n");
                pushOperand((IROperand*)ops.get((u32)1), out);
                out.appendCString("    i16x8.extend_high_i8x16_u\n    i16x8.mul\n");
                out.appendCString("    i8x16.shuffle 0 2 4 6 8 10 12 14 16 18 20 22 24 26 28 30\n");
                setResult(res, false, out);
                return true;
            }
            String* shape = bitwise ? (String*)0 : Wasm32.laneShape(lane);
            if (!bitwise && shape == (String*)0) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            pushOperand((IROperand*)ops.get((u32)1), out);
            if (bitwise)
                out.appendFormat("    v128.%s\n",
                    op.equals(String.withCString("VAnd")) ? "and"
                  : op.equals(String.withCString("VOr"))  ? "or" : "xor");
            else
                out.appendFormat("    %s.%s\n", shape.cString(),
                    op.equals(String.withCString("VAdd")) ? "add"
                  : op.equals(String.withCString("VSub")) ? "sub" : "mul");
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("VMax")) || op.equals(String.withCString("VMin"))) {
            if (res == 0 || ops.count() < (u32)2) return true;
            String* lane = Wasm32.laneOf(res.ty());
            String* shape = Wasm32.laneShape(lane);
            if (shape == (String*)0) return true;
            bool flt = lane != (String*)0 && lane.equals(String.withCString("F32"));
            bool sgn = Wasm32.isSignedTy(lane);
            String* mn = op.equals(String.withCString("VMax"))
                ? (flt ? String.withCString("max")
                       : (sgn ? String.withCString("max_s") : String.withCString("max_u")))
                : (flt ? String.withCString("min")
                       : (sgn ? String.withCString("min_s") : String.withCString("min_u")));
            pushOperand((IROperand*)ops.get((u32)0), out);
            pushOperand((IROperand*)ops.get((u32)1), out);
            out.appendFormat("    %s.%s\n", shape.cString(), mn.cString());
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("VICmp"))) {
            if (res == 0 || ops.count() < (u32)2) return true;
            String* shape = Wasm32.laneShape(Wasm32.laneOf(res.ty()));
            if (shape == (String*)0) return true;
            String* pred = insn.pred() == 0 ? String.withCString("EQ") : insn.pred();
            pushOperand((IROperand*)ops.get((u32)0), out);
            pushOperand((IROperand*)ops.get((u32)1), out);
            out.appendFormat("    %s.%s\n", shape.cString(), Wasm32.icmpMn(pred).cString());
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("VAddLP"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            IROperand* src = (IROperand*)ops.get((u32)0);
            String* lane = Wasm32.laneOf(Wasm32.tyOfOp(src));
            bool lane8 = lane != (String*)0 && (lane.equals(String.withCString("I8"))
                                             || lane.equals(String.withCString("U8")));
            pushOperand(src, out);
            out.appendCString(lane8 ? "    i16x8.extadd_pairwise_i8x16_u\n"
                                    : "    i32x4.extadd_pairwise_i16x8_u\n");
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("VReduceAdd"))) {
            // i32/u32 lanes (.4s) by construction; wasm has no horizontal
            // add — extract the four lanes and chain scalar adds.
            if (res == 0 || ops.count() < (u32)1) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendCString("    i32x4.extract_lane 0\n");
            for (u32 k = (u32)1; k <= (u32)3; k = k + (u32)1) {
                pushOperand((IROperand*)ops.get((u32)0), out);
                out.appendFormat("    i32x4.extract_lane %lu\n    i32.add\n", k);
            }
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("VReduceMax")) || op.equals(String.withCString("VReduceMin"))) {
            // Seed the result local with lane 0, then fold lanes 1..3
            // through `select` (each lane is extracted twice — the running
            // value lives in the result local, so no scratch local).
            if (res == 0 || ops.count() < (u32)1) return true;
            bool sgn = Wasm32.isSignedTy(res.ty());
            String* cmp = op.equals(String.withCString("VReduceMax"))
                ? (sgn ? String.withCString("gt_s") : String.withCString("gt_u"))
                : (sgn ? String.withCString("lt_s") : String.withCString("lt_u"));
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendFormat("    i32x4.extract_lane 0\n    local.set $v%lu\n",
                             vnum(res.pid()));
            for (u32 k = (u32)1; k <= (u32)3; k = k + (u32)1) {
                out.appendFormat("    local.get $v%lu\n", vnum(res.pid()));
                pushOperand((IROperand*)ops.get((u32)0), out);
                out.appendFormat("    i32x4.extract_lane %lu\n", k);
                out.appendFormat("    local.get $v%lu\n", vnum(res.pid()));
                pushOperand((IROperand*)ops.get((u32)0), out);
                out.appendFormat("    i32x4.extract_lane %lu\n", k);
                out.appendFormat("    i32.%s\n    select\n    local.set $v%lu\n",
                                 cmp.cString(), vnum(res.pid()));
            }
            return true;
        }
        return false;
    }

    static String* intBinMn(String* op)
    {
        if (op.equals(String.withCString("Add"))) return String.withCString("add");
        if (op.equals(String.withCString("Sub"))) return String.withCString("sub");
        if (op.equals(String.withCString("Mul"))) return String.withCString("mul");
        if (op.equals(String.withCString("And"))) return String.withCString("and");
        if (op.equals(String.withCString("Or")))  return String.withCString("or");
        if (op.equals(String.withCString("Xor"))) return String.withCString("xor");
        return (String*)0;
    }

    static String* icmpMn(String* p)
    {
        if (p.equals(String.withCString("EQ")))  return String.withCString("eq");
        if (p.equals(String.withCString("NE")))  return String.withCString("ne");
        if (p.equals(String.withCString("SLT"))) return String.withCString("lt_s");
        if (p.equals(String.withCString("SGT"))) return String.withCString("gt_s");
        if (p.equals(String.withCString("SLE"))) return String.withCString("le_s");
        if (p.equals(String.withCString("SGE"))) return String.withCString("ge_s");
        if (p.equals(String.withCString("ULT"))) return String.withCString("lt_u");
        if (p.equals(String.withCString("UGT"))) return String.withCString("gt_u");
        if (p.equals(String.withCString("ULE"))) return String.withCString("le_u");
        if (p.equals(String.withCString("UGE"))) return String.withCString("ge_u");
        return String.withCString("eq");
    }

    static bool icmpUnsigned(String* p)
    {
        return p.equals(String.withCString("ULT")) || p.equals(String.withCString("UGT"))
            || p.equals(String.withCString("ULE")) || p.equals(String.withCString("UGE"));
    }

    static String* fcmpMn(String* p)
    {
        if (p.equals(String.withCString("OEQ"))) return String.withCString("eq");
        if (p.equals(String.withCString("ONE"))) return String.withCString("ne");
        if (p.equals(String.withCString("OLT"))) return String.withCString("lt");
        if (p.equals(String.withCString("OGT"))) return String.withCString("gt");
        if (p.equals(String.withCString("OLE"))) return String.withCString("le");
        if (p.equals(String.withCString("OGE"))) return String.withCString("ge");
        return String.withCString("eq");
    }

    bool emitCore(IRInsn* insn, String* op, String* out)
    {
        IRValue* res = insn.res();
        Array* ops = Wasm32.dataOps(insn);

        if (op.equals(String.withCString("Const"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            setResult(res, true, out);
            return true;
        }
        if (op.equals(String.withCString("Copy")) || op.equals(String.withCString("Bitcast"))
         || op.equals(String.withCString("IntToPtr")) || op.equals(String.withCString("PtrToInt"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            IROperand* src = (IROperand*)ops.get((u32)0);
            String* st = Wasm32.tyOfOp(src);
            pushOperand(src, out);
            String* from = Wasm32.valType(st);
            String* to = Wasm32.valType(res.ty());
            if (!from.equals(to)) {
                if (from.equals(String.withCString("f32")) && to.equals(String.withCString("i32")))
                    out.appendCString("    i32.reinterpret_f32\n");
                else if (from.equals(String.withCString("i32")) && to.equals(String.withCString("f32")))
                    out.appendCString("    f32.reinterpret_i32\n");
                else if (from.equals(String.withCString("f64")) && to.equals(String.withCString("i64")))
                    out.appendCString("    i64.reinterpret_f64\n");
                else if (from.equals(String.withCString("i64")) && to.equals(String.withCString("f64")))
                    out.appendCString("    f64.reinterpret_i64\n");
                else if (from.equals(String.withCString("i64")) && to.equals(String.withCString("i32")))
                    out.appendCString("    i32.wrap_i64\n");
                else if (from.equals(String.withCString("i32")) && to.equals(String.withCString("i64")))
                    out.appendCString("    i64.extend_i32_u\n");
            }
            setResult(res, !op.equals(String.withCString("Copy")), out);
            return true;
        }
        String* mn = Wasm32.intBinMn(op);
        if (mn != (String*)0) {
            if (res == 0 || ops.count() < (u32)2) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            pushOperand((IROperand*)ops.get((u32)1), out);
            out.appendFormat("    %s.%s\n", Wasm32.valType(res.ty()).cString(), mn.cString());
            setResult(res, true, out);
            return true;
        }
        if (op.equals(String.withCString("SDiv")) || op.equals(String.withCString("UDiv"))
         || op.equals(String.withCString("SRem")) || op.equals(String.withCString("URem"))) {
            if (res == 0 || ops.count() < (u32)2) return true;
            String* m = op.equals(String.withCString("SDiv")) ? String.withCString("div_s")
                      : op.equals(String.withCString("UDiv")) ? String.withCString("div_u")
                      : op.equals(String.withCString("SRem")) ? String.withCString("rem_s")
                      : String.withCString("rem_u");
            pushOperand((IROperand*)ops.get((u32)0), out);
            pushOperand((IROperand*)ops.get((u32)1), out);
            out.appendFormat("    %s.%s\n", Wasm32.valType(res.ty()).cString(), m.cString());
            setResult(res, true, out);
            return true;
        }
        if (op.equals(String.withCString("Neg"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            String* p = Wasm32.valType(res.ty());
            out.appendFormat("    %s.const 0\n", p.cString());
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendFormat("    %s.sub\n", p.cString());
            setResult(res, true, out);
            return true;
        }
        if (op.equals(String.withCString("Not"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            String* p = Wasm32.valType(res.ty());
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendFormat("    %s.const -1\n    %s.xor\n", p.cString(), p.cString());
            setResult(res, true, out);
            return true;
        }
        if (op.equals(String.withCString("Phi")) || op.equals(String.withCString("DbgValue")))
            return true;
        return false;
    }

    bool emitShifts(IRInsn* insn, String* op, String* out)
    {
        IRValue* res = insn.res();
        Array* ops = Wasm32.dataOps(insn);

        if (op.equals(String.withCString("Shl")) || op.equals(String.withCString("LShr"))
         || op.equals(String.withCString("AShr"))) {
            if (res == 0 || ops.count() < (u32)2) return true;
            String* p = Wasm32.valType(res.ty());
            pushOperand((IROperand*)ops.get((u32)0), out);
            if (op.equals(String.withCString("LShr"))) {
                // Mask to the SOURCE's width first, only for signed narrow sources.
                String* st = Wasm32.tyOfOp((IROperand*)ops.get((u32)0));
                if (st != 0 && st.equals(String.withCString("I8")))
                    out.appendCString("    i32.const 255\n    i32.and\n");
                else if (st != 0 && st.equals(String.withCString("I16")))
                    out.appendCString("    i32.const 65535\n    i32.and\n");
            }
            pushOperand((IROperand*)ops.get((u32)1), out);
            widenCount((IROperand*)ops.get((u32)1), p, out);
            String* m2 = op.equals(String.withCString("Shl")) ? String.withCString("shl")
                       : op.equals(String.withCString("LShr")) ? String.withCString("shr_u")
                       : String.withCString("shr_s");
            out.appendFormat("    %s.%s\n", p.cString(), m2.cString());
            setResult(res, true, out);
            return true;
        }
        if (op.equals(String.withCString("Rol")) || op.equals(String.withCString("Ror"))) {
            if (res == 0 || ops.count() < (u32)2) return true;
            u32 w = Wasm32.leafWidth(res.ty());
            String* p = Wasm32.valType(res.ty());
            if (w >= (u32)4 || p.equals(String.withCString("i64"))) {
                pushOperand((IROperand*)ops.get((u32)0), out);
                pushOperand((IROperand*)ops.get((u32)1), out);
                widenCount((IROperand*)ops.get((u32)1), p, out);
                out.appendFormat("    %s.%s\n", p.cString(),
                                 op.equals(String.withCString("Rol")) ? "rotl" : "rotr");
                setResult(res, true, out);
                return true;
            }
            u32 bits = w * (u32)8;
            u32 mask = ((u32)1 << bits) - (u32)1;
            bool rol = op.equals(String.withCString("Rol"));
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendFormat("    i32.const %lu\n    i32.and\n", mask);
            pushOperand((IROperand*)ops.get((u32)1), out);
            out.appendFormat("    i32.const %lu\n    i32.rem_u\n    i32.%s\n",
                             bits, rol ? "shl" : "shr_u");
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendFormat("    i32.const %lu\n    i32.and\n", mask);
            out.appendFormat("    i32.const %lu\n", bits);
            pushOperand((IROperand*)ops.get((u32)1), out);
            out.appendFormat("    i32.const %lu\n    i32.rem_u\n    i32.sub\n", bits);
            out.appendFormat("    i32.const %lu\n    i32.rem_u\n    i32.%s\n    i32.or\n",
                             bits, rol ? "shr_u" : "shl");
            setResult(res, true, out);
            return true;
        }
        return false;
    }

    bool emitCmpSel(IRInsn* insn, String* op, String* out)
    {
        IRValue* res = insn.res();
        Array* ops = Wasm32.dataOps(insn);

        if (op.equals(String.withCString("ICmp"))) {
            if (res == 0 || ops.count() < (u32)2) return true;
            String* at = Wasm32.tyOfOp((IROperand*)ops.get((u32)0));
            String* p = Wasm32.is64Ty(at) ? String.withCString("i64") : String.withCString("i32");
            String* pred = insn.pred() == 0 ? String.withCString("EQ") : insn.pred();
            bool unsignedPred = Wasm32.icmpUnsigned(pred);
            bool narrowSigned = at != 0 && (at.equals(String.withCString("I8"))
                                         || at.equals(String.withCString("I16")));
            String* mask = at != 0 && at.equals(String.withCString("I8"))
                ? String.withCString("    i32.const 255\n    i32.and\n")
                : String.withCString("    i32.const 65535\n    i32.and\n");
            pushOperand((IROperand*)ops.get((u32)0), out);
            if (unsignedPred && narrowSigned) out.append(mask);
            pushOperand((IROperand*)ops.get((u32)1), out);
            if (unsignedPred && narrowSigned) out.append(mask);
            out.appendFormat("    %s.%s\n", p.cString(), Wasm32.icmpMn(pred).cString());
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("FCmp"))) {
            if (res == 0 || ops.count() < (u32)2) return true;
            String* at = Wasm32.tyOfOp((IROperand*)ops.get((u32)0));
            String* pred = insn.pred() == 0 ? String.withCString("OEQ") : insn.pred();
            pushOperand((IROperand*)ops.get((u32)0), out);
            pushOperand((IROperand*)ops.get((u32)1), out);
            out.appendFormat("    %s.%s\n",
                             (at != 0 && at.equals(String.withCString("F32"))) ? "f32" : "f64",
                             Wasm32.fcmpMn(pred).cString());
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("Select"))) {
            if (res == 0 || ops.count() < (u32)3) return true;
            pushOperand((IROperand*)ops.get((u32)1), out);
            pushOperand((IROperand*)ops.get((u32)2), out);
            pushCondition((IROperand*)ops.get((u32)0), out);
            out.appendCString("    select\n");
            setResult(res, false, out);
            return true;
        }
        return false;
    }

    bool emitFloat(IRInsn* insn, String* op, String* out)
    {
        IRValue* res = insn.res();
        Array* ops = Wasm32.dataOps(insn);

        if (op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub"))
         || op.equals(String.withCString("FMul")) || op.equals(String.withCString("FDiv"))) {
            if (res == 0 || ops.count() < (u32)2) return true;
            String* m3 = op.equals(String.withCString("FAdd")) ? String.withCString("add")
                       : op.equals(String.withCString("FSub")) ? String.withCString("sub")
                       : op.equals(String.withCString("FMul")) ? String.withCString("mul")
                       : String.withCString("div");
            pushOperand((IROperand*)ops.get((u32)0), out);
            pushOperand((IROperand*)ops.get((u32)1), out);
            out.appendFormat("    %s.%s\n", Wasm32.valType(res.ty()).cString(), m3.cString());
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("FNeg"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendFormat("    %s.neg\n", Wasm32.valType(res.ty()).cString());
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("FSqrt"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendFormat("    %s.sqrt\n", Wasm32.valType(res.ty()).cString());
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("Phi")) || op.equals(String.withCString("DbgValue")))
            return true;
        return false;
    }

    bool emitCasts(IRInsn* insn, String* op, String* out)
    {
        IRValue* res = insn.res();
        Array* ops = Wasm32.dataOps(insn);

        if (op.equals(String.withCString("ZExt")) || op.equals(String.withCString("SExt"))
         || op.equals(String.withCString("Trunc"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            IROperand* src = (IROperand*)ops.get((u32)0);
            String* st = Wasm32.tyOfOp(src);
            pushOperand(src, out);
            bool src64 = Wasm32.is64Ty(st);
            bool dst64 = Wasm32.is64Ty(res.ty());
            if (op.equals(String.withCString("ZExt")) && st != 0) {
                if (st.equals(String.withCString("I8")))
                    out.appendCString("    i32.const 255\n    i32.and\n");
                if (st.equals(String.withCString("I16")))
                    out.appendCString("    i32.const 65535\n    i32.and\n");
            }
            if (src64 && !dst64) out.appendCString("    i32.wrap_i64\n");
            else if (!src64 && dst64)
                out.appendCString(op.equals(String.withCString("SExt"))
                    ? "    i64.extend_i32_s\n" : "    i64.extend_i32_u\n");
            setResult(res, true, out);
            return true;
        }
        if (op.equals(String.withCString("FpExt"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendCString("    f64.promote_f32\n");
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("FpTrunc"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendCString("    f32.demote_f64\n");
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("SIToFp")) || op.equals(String.withCString("UIToFp"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            IROperand* src = (IROperand*)ops.get((u32)0);
            String* st = Wasm32.tyOfOp(src);
            pushOperand(src, out);
            out.appendFormat("    %s.convert_%s_%s\n",
                             Wasm32.valType(res.ty()).cString(),
                             Wasm32.is64Ty(st) ? "i64" : "i32",
                             op.equals(String.withCString("SIToFp")) ? "s" : "u");
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("FpToSI")) || op.equals(String.withCString("FpToUI"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            IROperand* src = (IROperand*)ops.get((u32)0);
            String* st = Wasm32.tyOfOp(src);
            pushOperand(src, out);
            out.appendFormat("    %s.trunc_sat_%s_%s\n",
                             Wasm32.is64Ty(res.ty()) ? "i64" : "i32",
                             (st != 0 && st.equals(String.withCString("F32"))) ? "f32" : "f64",
                             op.equals(String.withCString("FpToSI")) ? "s" : "u");
            setResult(res, true, out);
            return true;
        }
        return false;
    }

    // A scalar load of `t` from the address on the stack.
    void emitScalarLoad(String* t, String* out)
    {
        u32 w = Wasm32.leafWidth(t);
        if (w == (u32)0) w = (u32)4;
        bool sgn = Wasm32.isSignedTy(t);
        String* p = Wasm32.valType(t);
        if (p.equals(String.withCString("i32")) || p.equals(String.withCString("i64"))) {
            if (w == (u32)1)
                out.appendFormat("    %s.load8_%s\n", p.cString(), sgn ? "s" : "u");
            else if (w == (u32)2)
                out.appendFormat("    %s.load16_%s\n", p.cString(), sgn ? "s" : "u");
            else if (w == (u32)4 && p.equals(String.withCString("i64")))
                out.appendFormat("    i64.load32_%s\n", sgn ? "s" : "u");
            else
                out.appendFormat("    %s.load\n", p.cString());
        } else {
            out.appendFormat("    %s.load\n", p.cString());
        }
    }

    // A scalar store of `t` (address, value already on the stack).
    void emitScalarStore(String* t, String* out)
    {
        u32 w = t == 0 ? (u32)4 : Wasm32.leafWidth(t);
        if (w == (u32)0) w = (u32)4;
        String* p = Wasm32.valType(t);
        if (p.equals(String.withCString("i32")) || p.equals(String.withCString("i64"))) {
            if (w == (u32)1) out.appendFormat("    %s.store8\n", p.cString());
            else if (w == (u32)2) out.appendFormat("    %s.store16\n", p.cString());
            else if (w == (u32)4 && p.equals(String.withCString("i64")))
                out.appendCString("    i64.store32\n");
            else out.appendFormat("    %s.store\n", p.cString());
        } else {
            out.appendFormat("    %s.store\n", p.cString());
        }
    }

    bool emitMemoryOps(IRInsn* insn, String* op, String* out)
    {
        IRValue* res = insn.res();
        Array* ops = Wasm32.dataOps(insn);

        if (op.equals(String.withCString("Load")) || op.equals(String.withCString("LoadVolatile"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            String* rt = res.ty();
            if (Wasm32.isAggTy(rt)) {
                out.appendFormat("    local.get $v%lu\n", vnum(res.pid()));
                pushOperand((IROperand*)ops.get((u32)0), out);
                out.appendFormat("    i32.const %lu\n    memory.copy\n",
                                 aggSize(layoutOf(rt)));
                return true;
            }
            pushOperand((IROperand*)ops.get((u32)0), out);
            emitScalarLoad(rt, out);
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("Store")) || op.equals(String.withCString("StoreVolatile"))) {
            if (ops.count() < (u32)2) return true;
            IROperand* vop = (IROperand*)ops.get((u32)1);
            String* vt = Wasm32.tyOfOp(vop);
            if (vt != 0 && Wasm32.isAggTy(vt)) {
                pushOperand((IROperand*)ops.get((u32)0), out);
                pushOperand(vop, out);
                out.appendFormat("    i32.const %lu\n    memory.copy\n",
                                 aggSize(layoutOf(vt)));
                return true;
            }
            pushOperand((IROperand*)ops.get((u32)0), out);
            pushOperand(vop, out);
            emitScalarStore(vt, out);
            return true;
        }
        if (op.equals(String.withCString("MemCopy")) || op.equals(String.withCString("MemSet"))) {
            if (ops.count() < (u32)3) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            pushOperand((IROperand*)ops.get((u32)1), out);
            pushOperand((IROperand*)ops.get((u32)2), out);
            out.appendCString(op.equals(String.withCString("MemCopy"))
                ? "    memory.copy\n" : "    memory.fill\n");
            return true;
        }
        if (op.equals(String.withCString("AddrOf"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("FieldAddr"))) {
            if (res == 0 || ops.count() < (u32)2) return true;
            IROperand* base = (IROperand*)ops.get((u32)0);
            String* bt = Wasm32.tyOfOp(base);
            IRLayout* lay = layoutOf(Wasm32.pointeeOf(bt));
            u32 off = fieldOffset(lay, (u32)((IROperand*)ops.get((u32)1)).imm());
            pushOperand(base, out);
            if (off != (u32)0)
                out.appendFormat("    i32.const %lu\n    i32.add\n", off);
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("ElementAddr"))) {
            if (res == 0 || ops.count() < (u32)2) return true;
            IROperand* base = (IROperand*)ops.get((u32)0);
            String* bt = Wasm32.tyOfOp(base);
            String* pointee = Wasm32.pointeeOf(bt);
            u32 es = (u32)1;
            if (pointee != (String*)0) {
                es = fieldWidth(pointee);
                if (es == (u32)0) es = (u32)1;
            }
            pushOperand(base, out);
            IROperand* idx = (IROperand*)ops.get((u32)1);
            pushOperand(idx, out);
            if (Wasm32.is64Ty(Wasm32.tyOfOp(idx))) out.appendCString("    i32.wrap_i64\n");
            if (es != (u32)1)
                out.appendFormat("    i32.const %lu\n    i32.mul\n", es);
            out.appendCString("    i32.add\n");
            setResult(res, false, out);
            return true;
        }
        return false;
    }

    bool emitAggOps(IRInsn* insn, String* op, String* out)
    {
        IRValue* res = insn.res();
        Array* ops = Wasm32.dataOps(insn);

        if (op.equals(String.withCString("AggBuild"))) {
            if (res == 0) return true;
            IRLayout* lay = layoutOf(res.ty());
            if (lay == (IRLayout*)0) return true;
            u32 nf = lay.fieldCount();
            for (u32 i = (u32)0; i < nf && i < ops.count(); i = i + (u32)1) {
                String* ft = lay.typeAt(i);
                u32 off = lay.offsetAt(i);
                if (Wasm32.memOrVoid(ft)) continue;
                out.appendFormat("    local.get $v%lu\n", vnum(res.pid()));
                if (Wasm32.isAggTy(ft)) {
                    if (off != (u32)0)
                        out.appendFormat("    i32.const %lu\n    i32.add\n", off);
                    pushOperand((IROperand*)ops.get(i), out);
                    out.appendFormat("    i32.const %lu\n    memory.copy\n",
                                     aggSize(layoutOf(ft)));
                    continue;
                }
                if (off != (u32)0)
                    out.appendFormat("    i32.const %lu\n    i32.add\n", off);
                pushOperand((IROperand*)ops.get(i), out);
                emitScalarStore(ft, out);
            }
            return true;
        }
        if (op.equals(String.withCString("AggExtract"))) {
            if (res == 0 || ops.count() < (u32)2) return true;
            IROperand* agg = (IROperand*)ops.get((u32)0);
            String* at = Wasm32.tyOfOp(agg);
            IRLayout* lay = layoutOf(at);
            u32 idx = (u32)((IROperand*)ops.get((u32)1)).imm();
            u32 off = fieldOffset(lay, idx);
            String* ft = (lay != 0 && idx < lay.fieldCount()) ? lay.typeAt(idx) : (String*)0;
            if (ft != 0 && Wasm32.isAggTy(ft)) {
                out.appendFormat("    local.get $v%lu\n", vnum(res.pid()));
                pushOperand(agg, out);
                if (off != (u32)0)
                    out.appendFormat("    i32.const %lu\n    i32.add\n", off);
                out.appendFormat("    i32.const %lu\n    memory.copy\n",
                                 aggSize(layoutOf(ft)));
                return true;
            }
            pushOperand(agg, out);
            if (off != (u32)0)
                out.appendFormat("    i32.const %lu\n    i32.add\n", off);
            emitScalarLoad(ft, out);
            setResult(res, false, out);
            return true;
        }
        return false;
    }

    bool emitCalls(IRInsn* insn, String* op, String* out)
    {
        IRValue* res = insn.res();
        Array* ops = Wasm32.dataOps(insn);

        if (op.equals(String.withCString("Call")) || op.equals(String.withCString("CallCloaked"))
         || op.equals(String.withCString("CallBanked"))) {
            if (ops.count() < (u32)1
                || ((IROperand*)ops.get((u32)0)).kind() != (u8)OPK_SYM) {
                if (res != 0) {
                    out.appendCString("    i32.const 0\n");
                    setResult(res, false, out);
                }
                return true;
            }
            IROperand* callee = (IROperand*)ops.get((u32)0);
            bool sretCall = res != 0 && Wasm32.isAggTy(res.ty());
            if (sretCall) out.appendFormat("    local.get $v%lu\n", vnum(res.pid()));
            for (u32 i = (u32)1; i < ops.count(); i = i + (u32)1)
                pushOperand((IROperand*)ops.get(i), out);
            out.appendFormat("    call $%s\n", callee.name().cString());
            if (res != 0 && !sretCall && !Wasm32.memOrVoid(res.ty()))
                setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("CallIndirect"))
         || op.equals(String.withCString("CallBankedIndirect"))) {
            if (ops.count() < (u32)1) return true;
            bool sretCall = res != 0 && Wasm32.isAggTy(res.ty());
            if (sretCall) out.appendFormat("    local.get $v%lu\n", vnum(res.pid()));
            Array* argTys = new Array();
            for (u32 i = (u32)1; i < ops.count(); i = i + (u32)1) {
                IROperand* a = (IROperand*)ops.get(i);
                String* t = Wasm32.tyOfOp(a);
                argTys.add((Object*)(t == 0 ? String.withCString("I32") : t));
                pushOperand(a, out);
            }
            pushOperand((IROperand*)ops.get((u32)0), out);
            String* ty = indirectTypeFor(argTys, sretCall ? (String*)0
                                        : (res == 0 ? (String*)0 : res.ty()));
            out.appendFormat("    call_indirect (type $%s)\n", ty.cString());
            if (res != 0 && !sretCall && !Wasm32.memOrVoid(res.ty()))
                setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("VTblDispatch"))) {
            if (ops.count() < (u32)2) return true;
            bool sretCall = res != 0 && Wasm32.isAggTy(res.ty());
            if (sretCall) out.appendFormat("    local.get $v%lu\n", vnum(res.pid()));
            Array* argTys = new Array();
            IROperand* recv = (IROperand*)ops.get((u32)0);
            String* rt = Wasm32.tyOfOp(recv);
            argTys.add((Object*)(rt == 0 ? String.withCString("I32") : rt));
            pushOperand(recv, out);
            for (u32 i = (u32)2; i < ops.count(); i = i + (u32)1) {
                IROperand* a = (IROperand*)ops.get(i);
                String* t = Wasm32.tyOfOp(a);
                argTys.add((Object*)(t == 0 ? String.withCString("I32") : t));
                pushOperand(a, out);
            }
            pushOperand(recv, out);
            out.appendCString("    i32.load\n");
            i64 slot = ((IROperand*)ops.get((u32)1)).imm();
            if (slot != (i64)0)
                out.appendFormat("    i32.const %s\n    i32.add\n",
                                 String.withI64(slot * (i64)4).cString());
            out.appendCString("    i32.load\n");
            String* ty = indirectTypeFor(argTys, sretCall ? (String*)0
                                        : (res == 0 ? (String*)0 : res.ty()));
            out.appendFormat("    call_indirect (type $%s)\n", ty.cString());
            if (res != 0 && !sretCall && !Wasm32.memOrVoid(res.ty()))
                setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("VTblLoad"))) {
            if (res == 0 || ops.count() < (u32)2) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendFormat("    local.set $v%lu\n", vnum(res.pid()));
            out.appendFormat("    local.get $v%lu\n    if\n", vnum(res.pid()));
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendCString("    i32.load\n");
            i64 slot = ((IROperand*)ops.get((u32)1)).imm();
            if (slot != (i64)0)
                out.appendFormat("    i32.const %s\n    i32.add\n",
                                 String.withI64(slot * (i64)4).cString());
            out.appendFormat("    i32.load\n    local.set $v%lu\n    else\n", vnum(res.pid()));
            out.appendFormat("    i32.const 0\n    local.set $v%lu\n    end\n", vnum(res.pid()));
            return true;
        }
        return false;
    }

    // With the receiver on the stack, push the protocol id and the method
    // index from a ProtoDispatch/ProtoLoad and look the table index up.
    void emitItabLookup(Array* ops, String* out)
    {
        out.appendFormat("    i32.const %ld\n", (i32)((IROperand*)ops.get((u32)1)).imm());
        out.appendFormat("    i32.const %ld\n", (i32)((IROperand*)ops.get((u32)2)).imm());
        out.appendCString("    call $__xtc_itab\n");
    }

    // The itable walk, one private copy per module that dispatches through
    // a protocol. Vtable word 1 is the itable: (protoId, &table) pairs ending
    // in a zero id, each table the protocol's methods in declaration order.
    // Both follow from the protocol alone, so a library and its client agree
    // on them without agreeing on vtable slot numbers (bug 266).
    void emitItabHelper(String* out)
    {
        out.appendCString(
        "  (func $__xtc_itab (param $o i32) (param $pid i32) (param $idx i32) (result i32)\n"
        "    (local $t i32)\n"
        "    local.get $o\n    i32.eqz\n"
        "    if\n      i32.const 0\n      return\n    end\n"
        "    local.get $o\n    i32.load\n    i32.load offset=4\n    local.tee $t\n    i32.eqz\n"
        "    if\n      i32.const 0\n      return\n    end\n"
        "    block $miss\n    loop $walk\n"
        "    local.get $t\n    i32.load\n    local.get $pid\n    i32.eq\n"
        "    if\n"
        "      local.get $t\n      i32.load offset=4\n"
        "      local.get $idx\n      i32.const 2\n      i32.shl\n      i32.add\n"
        "      i32.load\n      return\n"
        "    end\n"
        "    local.get $t\n    i32.load\n    i32.eqz\n    br_if $miss\n"
        "    local.get $t\n    i32.const 8\n    i32.add\n    local.set $t\n"
        "    br $walk\n    end\n    end\n"
        "    i32.const 0\n  )\n");
    }

    bool emitArc(IRInsn* insn, String* op, String* out)
    {
        IRValue* res = insn.res();
        Array* ops = Wasm32.dataOps(insn);

        // [recv, protoId, index, args…]: the callee's table index comes from
        // the receiver's itable ($__xtc_itab, emitted into this module), and
        // the call is the VTblDispatch call_indirect. A class that does not
        // answer to the protocol gives index 0, which traps.
        if (op.equals(String.withCString("ProtoDispatch"))) {
            if (ops.count() < (u32)3) return true;
            bool sretCall = res != 0 && Wasm32.isAggTy(res.ty());
            if (sretCall) out.appendFormat("    local.get $v%lu\n", vnum(res.pid()));
            Array* argTys = new Array();
            IROperand* recv = (IROperand*)ops.get((u32)0);
            String* rt = Wasm32.tyOfOp(recv);
            argTys.add((Object*)(rt == 0 ? String.withCString("I32") : rt));
            pushOperand(recv, out);
            for (u32 i = (u32)3; i < ops.count(); i = i + (u32)1) {
                IROperand* a = (IROperand*)ops.get(i);
                String* t = Wasm32.tyOfOp(a);
                argTys.add((Object*)(t == 0 ? String.withCString("I32") : t));
                pushOperand(a, out);
            }
            pushOperand(recv, out);
            emitItabLookup(ops, out);
            String* ty = indirectTypeFor(argTys, sretCall ? (String*)0
                                        : (res == 0 ? (String*)0 : res.ty()));
            out.appendFormat("    call_indirect (type $%s)\n", ty.cString());
            if (res != 0 && !sretCall && !Wasm32.memOrVoid(res.ty()))
                setResult(res, false, out);
            return true;
        }
        // [recv, protoId, index]: the table index alone, 0 for a null
        // receiver or an unimplemented `optional` (the respondsTo test).
        if (op.equals(String.withCString("ProtoLoad"))) {
            if (res == 0 || ops.count() < (u32)3) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            emitItabLookup(ops, out);
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("Retain"))) {
            if (ops.count() < (u32)1) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendCString("    call $__xtc_retain\n");
            return true;
        }
        if (op.equals(String.withCString("Release")) || op.equals(String.withCString("Autorelease"))) {
            if (ops.count() < (u32)1) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendCString("    call $__xtc_release\n");
            return true;
        }
        if (op.equals(String.withCString("WeakRegister"))) {
            if (ops.count() < (u32)2) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            pushOperand((IROperand*)ops.get((u32)1), out);
            out.appendCString("    call $_xtc_weak_register\n");
            return true;
        }
        if (op.equals(String.withCString("WeakUnregister"))) {
            if (ops.count() < (u32)1) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendCString("    call $_xtc_weak_unregister\n");
            return true;
        }
        if (op.equals(String.withCString("WeakLoad"))) {
            if (res == 0 || ops.count() < (u32)1) return true;
            pushOperand((IROperand*)ops.get((u32)0), out);
            out.appendCString("    i32.load\n");
            setResult(res, false, out);
            return true;
        }
        if (op.equals(String.withCString("ClassDowncast"))
         || op.equals(String.withCString("ClassDowncastFailable"))) {
            if (res != 0 && ops.count() >= (u32)1) {
                pushOperand((IROperand*)ops.get((u32)0), out);
                setResult(res, false, out);
            }
            return true;
        }
        if (op.equals(String.withCString("Asm"))) {
            // No wasm lowering for inline asm, and this is FATAL — the module
            // written without it is missing the asm's effect and is refused
            // at load. Mirrors the reference; reported through the flag the
            // drivers already refuse on (bug 131's residue).
            Stdio.error(String.withCString("xcc-cg-wasm32: error: inline asm has no wasm lowering (guard the source with #if ARCH_wasm32)\n"));
            _fatalImport = true;
            return true;
        }
        if (op.equals(String.withCString("BankSave"))
         || op.equals(String.withCString("BankRestore"))
         || op.equals(String.withCString("BankSelectFor")))
            return true;
        return false;
    }

    // ── Phi edges and terminators ────────────────────────────────────────
    // Parallel copies: push every source, local.set every destination in
    // REVERSE — the operand-stack snapshot is the parallel read (#683).
    void emitPhiCopies(IRBlock* pred, IRBlock* succ, String* out)
    {
        Array* dsts = new Array();
        for (u32 p = (u32)0; p < succ.phis().count(); p = p + (u32)1) {
            IRInsn* phi = (IRInsn*)succ.phis().get(p);
            if (phi.res() == 0 || Wasm32.memOrVoid(phi.res().ty())) continue;
            for (u32 i = (u32)0; i + (u32)1 < phi.ops().count(); i = i + (u32)2) {
                IROperand* b = (IROperand*)phi.ops().get(i);
                if (b.kind() != (u8)OPK_BLOCK) continue;
                if (b.blk() != pred) continue;
                pushOperand((IROperand*)phi.ops().get(i + (u32)1), out);
                dsts.add((Object*)phi.res());
                break;
            }
        }
        for (u32 i = dsts.count(); i > (u32)0; i = i - (u32)1)
            out.appendFormat("    local.set $v%lu\n",
                             vnum(((IRValue*)dsts.get(i - (u32)1)).pid()));
    }

    void emitFramePop(WasmFnCtx* ctx, String* out)
    {
        if (ctx._frameSize == (u32)0) return;
        out.appendFormat("    local.get $fp\n    i32.const %lu\n    i32.add\n",
                         ctx._frameSize);
        out.appendCString("    global.set $__sp\n");
    }

    u32 blockIndexOf(IRFunc* fn, IRBlock* b)
    {
        for (u32 i = (u32)0; i < fn.blocks().count(); i = i + (u32)1)
            if ((IRBlock*)fn.blocks().get(i) == b) return i;
        return (u32)0;
    }

    // A block whose LAST instruction is a call whose result the terminator
    // immediately Returns fuses into `return_call` — same constraints as the
    // reference: no frame, no sret, matching valtypes (or both void), direct
    // Call or CallIndirect only.
    IRInsn* tailCallableInsn(IRBlock* b, IRFunc* fn, WasmFnCtx* ctx)
    {
        if (!_tailCalls || ctx._frameSize != (u32)0 || ctx._hasSret) return (IRInsn*)0;
        IRInsn* term = b.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("Return")))
            return (IRInsn*)0;
        if (b.insns().count() == (u32)0) return (IRInsn*)0;
        IRInsn* last = (IRInsn*)b.insns().get(b.insns().count() - (u32)1);
        bool isCall = last.op().equals(String.withCString("Call"));
        bool isInd  = last.op().equals(String.withCString("CallIndirect"));
        if (!isCall && !isInd) return (IRInsn*)0;
        Array* dops = Wasm32.dataOps(last);
        if (isCall && (dops.count() < (u32)1
            || ((IROperand*)dops.get((u32)0)).kind() != (u8)OPK_SYM))
            return (IRInsn*)0;
        IRValue* res = last.res();
        bool callVoid = res == (IRValue*)0 || Wasm32.memOrVoid(res.ty());
        bool fnVoid = fn.ret() == (String*)0 || Wasm32.memOrVoid(fn.ret());
        if (callVoid != fnVoid) return (IRInsn*)0;
        if (fnVoid) return last;
        if (Wasm32.isAggTy(res.ty()) || Wasm32.isAggTy(fn.ret())) return (IRInsn*)0;
        Array* tops = Wasm32.dataOps(term);
        if (tops.count() < (u32)1) return (IRInsn*)0;
        IROperand* val = (IROperand*)tops.get((u32)0);
        if (val.kind() != (u8)OPK_USE || val.val() == (IRValue*)0
            || val.val().pid() != res.pid())
            return (IRInsn*)0;
        if (!Wasm32.valType(res.ty()).equals(Wasm32.valType(fn.ret())))
            return (IRInsn*)0;
        return last;
    }

    void emitTailCall(IRInsn* call, IRFunc* fn, WasmFnCtx* ctx, String* out)
    {
        Array* ops = Wasm32.dataOps(call);
        if (call.op().equals(String.withCString("Call"))) {
            IROperand* callee = (IROperand*)ops.get((u32)0);
            for (u32 i = (u32)1; i < ops.count(); i = i + (u32)1)
                pushOperand((IROperand*)ops.get(i), out);
            out.appendFormat("    return_call $%s\n", callee.name().cString());
            return;
        }
        Array* argTys = new Array();
        for (u32 i = (u32)1; i < ops.count(); i = i + (u32)1) {
            IROperand* a = (IROperand*)ops.get(i);
            String* t = Wasm32.tyOfOp(a);
            argTys.add((Object*)(t == 0 ? String.withCString("I32") : t));
            pushOperand(a, out);
        }
        pushOperand((IROperand*)ops.get((u32)0), out);
        IRValue* res = call.res();
        String* rt = (res != (IRValue*)0 && !Wasm32.memOrVoid(res.ty()))
                   ? res.ty() : (String*)0;
        String* ty = indirectTypeFor(argTys, rt);
        out.appendFormat("    return_call_indirect (type $%s)\n", ty.cString());
    }

    void emitTerminator(IRInsn* term, IRBlock* b, IRFunc* fn, WasmFnCtx* ctx, String* out)
    {
        if (term == 0) { out.appendCString("    unreachable\n"); return; }
        String* op = term.op();
        Array* ops = Wasm32.dataOps(term);

        if (op.equals(String.withCString("Branch"))) {
            IRBlock* target = ops.count() > (u32)0
                ? ((IROperand*)ops.get((u32)0)).blk() : (IRBlock*)0;
            emitPhiCopies(b, target, out);
            out.appendFormat("    i32.const %lu\n    local.set $pc\n    br $dispatch\n",
                             blockIndexOf(fn, target));
            return;
        }
        if (op.equals(String.withCString("CondBranch"))) {
            IRBlock* thenB = ops.count() > (u32)1
                ? ((IROperand*)ops.get((u32)1)).blk() : (IRBlock*)0;
            IRBlock* elseB = ops.count() > (u32)2
                ? ((IROperand*)ops.get((u32)2)).blk() : (IRBlock*)0;
            pushCondition((IROperand*)ops.get((u32)0), out);
            out.appendCString("    if\n");
            emitPhiCopies(b, thenB, out);
            out.appendFormat("    i32.const %lu\n    local.set $pc\n    else\n",
                             blockIndexOf(fn, thenB));
            emitPhiCopies(b, elseB, out);
            out.appendFormat("    i32.const %lu\n    local.set $pc\n    end\n",
                             blockIndexOf(fn, elseB));
            out.appendCString("    br $dispatch\n");
            return;
        }
        if (op.equals(String.withCString("Return"))) {
            IROperand* val = ops.count() > (u32)0 ? (IROperand*)ops.get((u32)0) : (IROperand*)0;
            if (ctx._hasSret && val != 0) {
                out.appendCString("    local.get $sret\n");
                pushOperand(val, out);
                String* vt = Wasm32.tyOfOp(val);
                out.appendFormat("    i32.const %lu\n    memory.copy\n",
                                 aggSize(layoutOf(vt)));
                emitFramePop(ctx, out);
                out.appendCString("    return\n");
                return;
            }
            bool scalarRet = !Wasm32.memOrVoid(fn.ret()) && !Wasm32.isAggTy(fn.ret());
            if (scalarRet && val != 0) {
                emitFramePop(ctx, out);
                pushOperand(val, out);
                out.appendCString("    return\n");
            } else {
                emitFramePop(ctx, out);
                if (scalarRet)
                    out.appendFormat("    %s.const 0\n    return\n",
                                     Wasm32.valType(fn.ret()).cString());
                else
                    out.appendCString("    return\n");
            }
            return;
        }
        if (op.equals(String.withCString("Unreachable"))) {
            out.appendCString("    unreachable\n");
            return;
        }
        out.appendCString("    unreachable\n");
    }

    // ── Structured control flow (-O1+) ───────────────────────────────────
    // The dominator-tree relooper, twin of the original's structured mode:
    // reverse postorder by DFS (successors in terminator-operand order),
    // iterative-RPO immediate dominators, back edges → `loop`, merge nodes
    // → `block` ends, everything else inlined at its single forward branch.
    // An irreducible CFG (or an unknown terminator) returns null and the
    // function keeps the dispatch loop.

    void structureDFS(u32 u, WasmCFGPlan* plan, bool* visited, Array* post)
    {
        visited[u] = true;
        Array* s = (Array*)plan._succs.get(u);
        for (u32 i = (u32)0; i < s.count(); i = i + (u32)1) {
            u32 v = ((Number*)s.get(i)).asU32();
            if (!visited[v]) structureDFS(v, plan, visited, post);
        }
        post.add((Object*)Number.with(u));
    }

    // Does a dominate b?  (b's idom chain; the entry's idom is itself.)
    static bool wasmDominates(i32* idom, u32 a, u32 b)
    {
        while (true) {
            if (a == b) return true;
            i32 up = idom[b];
            if (up < (i32)0 || (u32)up == b) return false;
            b = (u32)up;
        }
        return false;
    }

    WasmCFGPlan* structurePlan(IRFunc* fn)
    {
        u32 n = fn.blocks().count();
        if (n == (u32)0) return (WasmCFGPlan*)0;
        WasmCFGPlan* plan = new WasmCFGPlan();
        plan.sizeTo(n);

        // Successor lists (edge-per-operand: a CondBranch with both arms on
        // one block contributes TWO edges — that is what makes it a merge
        // node below).
        for (u32 i = (u32)0; i < n; i = i + (u32)1) {
            IRBlock* b = (IRBlock*)fn.blocks().get(i);
            IRInsn* term = b.term();
            Array* s = new Array();
            if (term != 0) {
                String* op = term.op();
                bool isBr = op.equals(String.withCString("Branch"));
                bool isCond = op.equals(String.withCString("CondBranch"));
                if (isBr || isCond) {
                    for (u32 k = (u32)0; k < term.ops().count(); k = k + (u32)1) {
                        IROperand* o = (IROperand*)term.ops().get(k);
                        if (o.kind() != (u8)OPK_BLOCK) continue;
                        s.add((Object*)Number.with(blockIndexOf(fn, o.blk())));
                    }
                    if (isBr && s.count() != (u32)1) { plan.dropSlots(); return (WasmCFGPlan*)0; }
                    if (isCond && s.count() != (u32)2) { plan.dropSlots(); return (WasmCFGPlan*)0; }
                } else if (op.equals(String.withCString("Return"))
                        || op.equals(String.withCString("Unreachable"))) {
                } else {
                    plan.dropSlots();
                    return (WasmCFGPlan*)0;
                }
            }
            plan._succs.add((Object*)s);
        }

        // Reverse postorder from the entry (block 0). Unreachable blocks
        // keep rpoIndex -1 and are never emitted in structured mode.
        bool* visited = new bool[n];
        for (u32 i = (u32)0; i < n; i = i + (u32)1) visited[i] = false;
        Array* post = new Array();
        structureDFS((u32)0, plan, visited, post);
        delete visited;
        Array* rpo = new Array();     // rpo position -> Number@ block
        for (u32 i = post.count(); i > (u32)0; i = i - (u32)1) {
            u32 b = ((Number*)post.get(i - (u32)1)).asU32();
            plan._rpoIndex[b] = (i32)rpo.count();
            rpo.add((Object*)Number.with(b));
        }

        // Predecessor EDGE lists (reachable sources only), in block order.
        Array* preds = new Array();   // per block: Array@ of Number@
        for (u32 i = (u32)0; i < n; i = i + (u32)1) preds.add((Object*)new Array());
        for (u32 u = (u32)0; u < n; u = u + (u32)1) {
            if (plan._rpoIndex[u] < (i32)0) continue;
            Array* s = (Array*)plan._succs.get(u);
            for (u32 k = (u32)0; k < s.count(); k = k + (u32)1)
                ((Array*)preds.get(((Number*)s.get(k)).asU32()))
                    .add((Object*)Number.with(u));
        }

        // Immediate dominators — the iterative RPO algorithm, intersect
        // walking idom chains by RPO position.
        plan._idom[0] = (i32)0;
        bool changed = true;
        while (changed) {
            changed = false;
            for (u32 i = (u32)1; i < rpo.count(); i = i + (u32)1) {
                u32 b = ((Number*)rpo.get(i)).asU32();
                i32 newIdom = (i32)-1;
                Array* pl = (Array*)preds.get(b);
                for (u32 k = (u32)0; k < pl.count(); k = k + (u32)1) {
                    u32 p = ((Number*)pl.get(k)).asU32();
                    if (plan._idom[p] < (i32)0) continue;   // not yet reached
                    if (newIdom < (i32)0) { newIdom = (i32)p; continue; }
                    u32 a = p;
                    u32 c = (u32)newIdom;
                    while (a != c) {
                        while (plan._rpoIndex[a] > plan._rpoIndex[c])
                            a = (u32)plan._idom[a];
                        while (plan._rpoIndex[c] > plan._rpoIndex[a])
                            c = (u32)plan._idom[c];
                    }
                    newIdom = (i32)a;
                }
                if (plan._idom[b] != newIdom) { plan._idom[b] = newIdom; changed = true; }
            }
        }

        // Retreating edges: natural back edges mark loop headers; one whose
        // target does not dominate its source makes the CFG irreducible.
        for (u32 u = (u32)0; u < n; u = u + (u32)1) {
            if (plan._rpoIndex[u] < (i32)0) continue;
            Array* s = (Array*)plan._succs.get(u);
            for (u32 k = (u32)0; k < s.count(); k = k + (u32)1) {
                u32 v = ((Number*)s.get(k)).asU32();
                if (plan._rpoIndex[v] > plan._rpoIndex[u]) continue;
                if (!Wasm32.wasmDominates(plan._idom, v, u)) {
                    plan.dropSlots();
                    return (WasmCFGPlan*)0;    // irreducible
                }
                plan._loopHeader[v] = true;
            }
        }

        // Merge nodes: two or more forward in-edges.
        for (u32 v = (u32)0; v < n; v = v + (u32)1) {
            u32 fwd = (u32)0;
            if (plan._rpoIndex[v] >= (i32)0) {
                Array* pl = (Array*)preds.get(v);
                for (u32 k = (u32)0; k < pl.count(); k = k + (u32)1)
                    if (plan._rpoIndex[((Number*)pl.get(k)).asU32()]
                            < plan._rpoIndex[v]) fwd = fwd + (u32)1;
            }
            plan._mergeNode[v] = fwd >= (u32)2;
        }

        // Each block's dominator-tree children that are merge nodes, in
        // RPO order.
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            plan._mergeKids.add((Object*)new Array());
        for (u32 i = (u32)1; i < rpo.count(); i = i + (u32)1) {
            u32 b = ((Number*)rpo.get(i)).asU32();
            if (!plan._mergeNode[b]) continue;
            ((Array*)plan._mergeKids.get((u32)plan._idom[b]))
                .add((Object*)Number.with(b));
        }
        return plan;
    }

    // One structured edge: phi copies (the same parallel-copy scheme as the
    // dispatch form), then a `br` up to the loop header (back edge), a `br`
    // out to the block that ends where a merge node begins (forward edge),
    // or the target inlined in place (its single forward entry IS this edge).
    void emitStructuredBranchTo(u32 v, u32 u, WasmCFGPlan* plan, IRFunc* fn,
                                WasmFnCtx* ctx, String* out)
    {
        emitPhiCopies((IRBlock*)fn.blocks().get(u), (IRBlock*)fn.blocks().get(v), out);
        if (plan._rpoIndex[v] <= plan._rpoIndex[u])
            out.appendFormat("    br $L%lu\n", v);
        else if (plan._mergeNode[v])
            out.appendFormat("    br $B%lu\n", v);
        else
            emitStructuredTree(v, plan, fn, ctx, out);
    }

    void emitStructuredTerminator(IRInsn* term, u32 u, WasmCFGPlan* plan,
                                  IRFunc* fn, WasmFnCtx* ctx, String* out)
    {
        if (term != 0 && term.op().equals(String.withCString("Branch"))) {
            Array* ops = Wasm32.dataOps(term);
            u32 t = blockIndexOf(fn, ((IROperand*)ops.get((u32)0)).blk());
            emitStructuredBranchTo(t, u, plan, fn, ctx, out);
            return;
        }
        if (term != 0 && term.op().equals(String.withCString("CondBranch"))) {
            Array* ops = Wasm32.dataOps(term);
            u32 ti = blockIndexOf(fn, ((IROperand*)ops.get((u32)1)).blk());
            u32 ei = blockIndexOf(fn, ((IROperand*)ops.get((u32)2)).blk());
            pushCondition((IROperand*)ops.get((u32)0), out);
            out.appendCString("    if\n");
            emitStructuredBranchTo(ti, u, plan, fn, ctx, out);
            out.appendCString("    else\n");
            emitStructuredBranchTo(ei, u, plan, fn, ctx, out);
            out.appendCString("    end\n");
            return;
        }
        // Return / Unreachable / none — the shared path (no $pc involved).
        emitTerminator(term, (IRBlock*)fn.blocks().get(u), fn, ctx, out);
    }

    // The dominator-tree translation: emit X wrapped in `loop $L<X>` when it
    // heads one, with one `block $B<kid>` per merge-node dominator child —
    // opened outermost for the HIGHEST-RPO child, so each block's `end` sits
    // exactly where its merge node's code begins and every forward branch to
    // it is a `br` from inside.
    void emitStructuredTree(u32 X, WasmCFGPlan* plan, IRFunc* fn,
                            WasmFnCtx* ctx, String* out)
    {
        IRBlock* b = (IRBlock*)fn.blocks().get(X);
        if (plan._loopHeader[X])
            out.appendFormat("    loop $L%lu ;; %s\n", X,
                             b.name() == 0 ? "?" : b.name().cString());
        Array* kids = (Array*)plan._mergeKids.get(X);
        for (u32 j = kids.count(); j > (u32)0; j = j - (u32)1)
            out.appendFormat("    block $B%lu\n",
                             ((Number*)kids.get(j - (u32)1)).asU32());
        if (!plan._loopHeader[X])
            out.appendFormat("    ;; %s\n", b.name() == 0 ? "?" : b.name().cString());
        IRInsn* tail = tailCallableInsn(b, fn, ctx);
        for (u32 k = (u32)0; k < b.insns().count(); k = k + (u32)1) {
            IRInsn* one = (IRInsn*)b.insns().get(k);
            if (one == tail) continue;   // fused into return_call below
            emitInsn(one, fn, ctx, out);
        }
        if (tail != (IRInsn*)0) emitTailCall(tail, fn, ctx, out);
        else emitStructuredTerminator(b.term(), X, plan, fn, ctx, out);
        for (u32 j = (u32)0; j < kids.count(); j = j + (u32)1) {
            u32 kid = ((Number*)kids.get(j)).asU32();
            IRBlock* kb = (IRBlock*)fn.blocks().get(kid);
            out.appendFormat("    end ;; $B%lu — %s\n", kid,
                             kb.name() == 0 ? "?" : kb.name().cString());
            emitStructuredTree(kid, plan, fn, ctx, out);
        }
        if (plan._loopHeader[X])
            out.appendFormat("    end ;; $L%lu\n", X);
    }

    // ── Generated runtime ────────────────────────────────────────────────
    // Verbatim from the original: the 38-byte-header allocator (coalescing
    // free list over a bump region), ARC, the intrusive weak chain, dealloc
    // iteration, and the _xtc_new_* stubs.
    // link-libs: the app's runtime is the ONE runtime — export the entry
    // points a library imports (the twin of the oracle's X() block).
    String* rtExp(String* n)
    {
        String* s = String.withCString("");
        if (_linkLibs) s.appendFormat(" (export \"%s\")", n.cString());
        return s;
    }

    void emitRuntime(String* out)
    {
        String* deallocTy;
        {
            Array* one = new Array();
            one.add((Object*)String.withCString("I32"));
            deallocTy = indirectTypeFor(one, (String*)0);
        }

        out.appendFormat(
        "  (func $_xtc_alloc%s (param $c i32) (param $s i32) (param $d i32) (result i32)\n"
        "    (local $b i32) (local $p i32) (local $end i32) (local $total i32)\n"
        "    (local $prev i32) (local $cur i32) (local $sz i32) (local $rem i32)\n"
        "    local.get $c\n    local.get $s\n    i32.mul\n    local.set $b\n"
        "    local.get $b\n    i32.const 256\n    i32.lt_u\n"
        "    if\n      i32.const 256\n      local.set $b\n    end\n"
        "    local.get $b\n    i32.const 38\n    i32.add\n"
        "    i32.const 7\n    i32.add\n    i32.const -8\n    i32.and\n    local.set $total\n"
        "    ;; first-fit over the free list\n"
        "    i32.const 0\n    local.set $prev\n"
        "    global.get $__free\n    local.set $cur\n"
        "    block $miss\n    loop $scan\n"
        "    local.get $cur\n    i32.eqz\n    br_if $miss\n"
        "    local.get $cur\n    i32.load\n    local.tee $sz\n"
        "    local.get $total\n    i32.ge_u\n"
        "    if\n"
        "      local.get $sz\n      local.get $total\n      i32.sub\n      local.tee $rem\n"
        "      i32.const 64\n      i32.ge_u\n"
        "      if\n"
        "        ;; split: the remainder becomes a free block after the taken part\n"
        "        local.get $cur\n        local.get $total\n        i32.add\n        local.set $p\n"
        "        local.get $p\n        local.get $rem\n        i32.store\n"
        "        local.get $p\n        local.get $cur\n        i32.const 4\n        i32.add\n"
        "        i32.load\n        i32.store offset=4\n"
        "        local.get $prev\n"
        "        if\n"
        "          local.get $prev\n          local.get $p\n          i32.store offset=4\n"
        "        else\n"
        "          local.get $p\n          global.set $__free\n"
        "        end\n"
        "      else\n"
        "        ;; take the whole block\n"
        "        local.get $sz\n        local.set $total\n"
        "        local.get $prev\n"
        "        if\n"
        "          local.get $prev\n          local.get $cur\n          i32.load offset=4\n"
        "          i32.store offset=4\n"
        "        else\n"
        "          local.get $cur\n          i32.load offset=4\n          global.set $__free\n"
        "        end\n"
        "      end\n"
        "      local.get $cur\n      local.set $p\n"
        "      ;; ZERO the reused payload (fresh memory arrives zeroed; reused must too)\n"
        "      local.get $p\n      i32.const 38\n      i32.add\n"
        "      i32.const 0\n"
        "      local.get $total\n      i32.const 38\n      i32.sub\n"
        "      memory.fill\n"
        "      local.get $p\n      local.get $total\n      local.get $c\n      local.get $s\n"
        "      local.get $d\n      call $__xtc_hdr\n"
        "      local.get $p\n      i32.const 38\n      i32.add\n      return\n"
        "    end\n"
        "    local.get $cur\n    local.set $prev\n"
        "    local.get $cur\n    i32.load offset=4\n    local.set $cur\n"
        "    br $scan\n    end\n    end\n"
        "    ;; no fit: bump, growing the memory as needed\n"
        "    global.get $__heap\n    local.set $p\n"
        "    local.get $p\n    local.get $total\n    i32.add\n    local.set $end\n"
        "    block $grown\n    loop $g\n"
        "    memory.size\n    i32.const 16\n    i32.shl\n    local.get $end\n    i32.ge_u\n"
        "    br_if $grown\n"
        "    i32.const 16\n    memory.grow\n    i32.const -1\n    i32.eq\n"
        "    if\n      unreachable\n    end\n"
        "    br $g\n    end\n    end\n"
        "    local.get $end\n    global.set $__heap\n"
        "    local.get $p\n    local.get $total\n    local.get $c\n    local.get $s\n"
        "    local.get $d\n    call $__xtc_hdr\n"
        "    local.get $p\n    i32.const 38\n    i32.add\n  )\n"
        "  (func $__xtc_hdr (param $p i32) (param $total i32) (param $c i32)"
        " (param $s i32) (param $d i32)\n"
        "    local.get $p\n    i32.const 1481920322\n    i32.store\n"
        "    local.get $p\n    i32.const 4\n    i32.add\n    local.get $s\n    i32.store\n"
        "    local.get $p\n    i32.const 12\n    i32.add\n    local.get $c\n    i32.store\n"
        "    local.get $p\n    i32.const 20\n    i32.add\n    local.get $d\n    i32.store\n"
        "    local.get $p\n    i32.const 28\n    i32.add\n    i32.const 0\n    i32.store\n"
        "    local.get $p\n    i32.const 32\n    i32.add\n    local.get $total\n    i32.store\n"
        "    local.get $p\n    i32.const 36\n    i32.add\n    i32.const 1\n    i32.store16\n  )\n"
        "  (func $_xtc_free (param $blk i32)\n"
        "    (local $sz i32) (local $prev i32) (local $cur i32)\n"
        "    local.get $blk\n    i32.const 32\n    i32.add\n    i32.load\n    local.set $sz\n"
        "    ;; poison the magic so a dangling .length / release reads garbage loudly\n"
        "    local.get $blk\n    i32.const 0\n    i32.store\n"
        "    ;; address-ordered insertion\n"
        "    i32.const 0\n    local.set $prev\n"
        "    global.get $__free\n    local.set $cur\n"
        "    block $found\n    loop $walk\n"
        "    local.get $cur\n    i32.eqz\n    br_if $found\n"
        "    local.get $cur\n    local.get $blk\n    i32.gt_u\n    br_if $found\n"
        "    local.get $cur\n    local.set $prev\n"
        "    local.get $cur\n    i32.load offset=4\n    local.set $cur\n"
        "    br $walk\n    end\n    end\n"
        "    ;; coalesce forward: blk + sz == cur → absorb cur\n"
        "    local.get $cur\n"
        "    if\n"
        "      local.get $blk\n      local.get $sz\n      i32.add\n"
        "      local.get $cur\n      i32.eq\n"
        "      if\n"
        "        local.get $sz\n        local.get $cur\n        i32.load\n        i32.add\n"
        "        local.set $sz\n"
        "        local.get $cur\n        i32.load offset=4\n        local.set $cur\n"
        "      end\n"
        "    end\n"
        "    ;; coalesce backward: prev + prev.size == blk → absorb into prev\n"
        "    local.get $prev\n"
        "    if\n"
        "      local.get $prev\n      local.get $prev\n      i32.load\n      i32.add\n"
        "      local.get $blk\n      i32.eq\n"
        "      if\n"
        "        local.get $prev\n        local.get $prev\n        i32.load\n"
        "        local.get $sz\n        i32.add\n        i32.store\n"
        "        local.get $prev\n        local.get $cur\n        i32.store offset=4\n"
        "        return\n"
        "      end\n"
        "    end\n"
        "    local.get $blk\n    local.get $sz\n    i32.store\n"
        "    local.get $blk\n    local.get $cur\n    i32.store offset=4\n"
        "    local.get $prev\n"
        "    if\n"
        "      local.get $prev\n      local.get $blk\n      i32.store offset=4\n"
        "    else\n"
        "      local.get $blk\n      global.set $__free\n"
        "    end\n  )\n",
        rtExp(String.withCString("_xtc_alloc")).cString());

        if (_needsHeapInfo) {
            out.appendFormat(
            "  (func $_xtc_heap_total_bytes%s (result i32)\n"
            "    memory.size\n    i32.const 16\n    i32.shl\n"
            "    i32.const 1048576\n    i32.sub\n  )\n"
            "  (func $_xtc_heap_free_bytes%s (result i32)\n"
            "    (local $cur i32) (local $sum i32)\n"
            "    memory.size\n    i32.const 16\n    i32.shl\n"
            "    global.get $__heap\n    i32.sub\n    local.set $sum\n"
            "    global.get $__free\n    local.set $cur\n"
            "    block $done\n    loop $walk\n"
            "    local.get $cur\n    i32.eqz\n    br_if $done\n"
            "    local.get $cur\n    i32.load\n    local.get $sum\n    i32.add\n"
            "    local.set $sum\n"
            "    local.get $cur\n    i32.load offset=4\n    local.set $cur\n"
            "    br $walk\n    end\n    end\n"
            "    local.get $sum\n  )\n"
            "  (func $_xtc_heap_largest%s (result i32)\n"
            "    (local $cur i32) (local $max i32)\n"
            "    memory.size\n    i32.const 16\n    i32.shl\n"
            "    global.get $__heap\n    i32.sub\n    local.set $max\n"
            "    global.get $__free\n    local.set $cur\n"
            "    block $done\n    loop $walk\n"
            "    local.get $cur\n    i32.eqz\n    br_if $done\n"
            "    local.get $cur\n    i32.load\n    local.get $max\n    i32.gt_u\n"
            "    if\n      local.get $cur\n      i32.load\n      local.set $max\n    end\n"
            "    local.get $cur\n    i32.load offset=4\n    local.set $cur\n"
            "    br $walk\n    end\n    end\n"
            "    local.get $max\n  )\n",
            rtExp(String.withCString("_xtc_heap_total_bytes")).cString(),
            rtExp(String.withCString("_xtc_heap_free_bytes")).cString(),
            rtExp(String.withCString("_xtc_heap_largest")).cString());
        }

        // The 16-bit count saturates at 65535: retain stops there instead of
        // wrapping to 0, and release leaves a saturated count alone, so the
        // object is leaked rather than freed while still referenced (bug 261).
        out.appendFormat(
        "  (func $__xtc_retain%s (param $p i32)\n"
        "    (local $rc i32)\n"
        "    local.get $p\n    i32.const 1048576\n    i32.lt_u\n"
        "    if\n      return\n    end\n"
        "    local.get $p\n    i32.const 2\n    i32.sub\n    i32.load16_u\n"
        "    local.tee $rc\n    i32.eqz\n"
        "    if\n      return\n    end\n"
        "    local.get $rc\n    i32.const 65535\n    i32.eq\n"
        "    if\n      return\n    end\n"
        "    local.get $p\n    i32.const 2\n    i32.sub\n"
        "    local.get $rc\n    i32.const 1\n    i32.add\n    i32.store16\n  )\n",
        rtExp(String.withCString("__xtc_retain")).cString());

        out.appendFormat(
        "  (func $__xtc_release%s (param $p i32)\n"
        "    (local $rc i32)\n"
        "    local.get $p\n    i32.const 1048576\n    i32.lt_u\n"
        "    if\n      return\n    end\n"
        "    local.get $p\n    i32.const 2\n    i32.sub\n    i32.load16_u\n"
        "    local.tee $rc\n    i32.eqz\n"
        "    if\n      return\n    end\n"
        "    local.get $rc\n    i32.const 65535\n    i32.eq\n"
        "    if\n      return\n    end\n"
        "    local.get $p\n    i32.const 2\n    i32.sub\n"
        "    local.get $rc\n    i32.const 1\n    i32.sub\n    i32.store16\n"
        "    local.get $rc\n    i32.const 1\n    i32.eq\n"
        "    if\n"
        "      local.get $p\n      call $_xtc_dealloc\n"
        "    end\n  )\n",
        rtExp(String.withCString("__xtc_release")).cString());

        out.appendFormat(
        "  (func $_xtc_weak_unregister%s (param $s i32)\n"
        "    (local $pp i32) (local $nx i32)\n"
        "    local.get $s\n    i32.const 8\n    i32.sub\n    i32.load\n    local.tee $pp\n"
        "    i32.eqz\n    if\n      return\n    end\n"
        "    local.get $s\n    i32.const 4\n    i32.sub\n    i32.load\n    local.set $nx\n"
        "    local.get $pp\n    local.get $nx\n    i32.store\n"
        "    local.get $nx\n"
        "    if\n"
        "      local.get $nx\n      i32.const 8\n      i32.sub\n      local.get $pp\n      i32.store\n"
        "    end\n"
        "    local.get $s\n    i32.const 8\n    i32.sub\n    i32.const 0\n    i32.store\n"
        "    local.get $s\n    i32.const 4\n    i32.sub\n    i32.const 0\n    i32.store\n  )\n",
        rtExp(String.withCString("_xtc_weak_unregister")).cString());
        out.appendFormat(
        "  (func $_xtc_weak_register%s (param $s i32) (param $o i32)\n"
        "    (local $nx i32)\n"
        "    local.get $s\n    call $_xtc_weak_unregister\n"
        "    local.get $o\n    i32.eqz\n    if\n      return\n    end\n"
        "    local.get $o\n    i32.const 1048576\n    i32.lt_u\n    if\n      return\n    end\n"
        "    local.get $o\n    i32.const 38\n    i32.sub\n    i32.load\n"
        "    i32.const 1481920322\n    i32.ne\n    if\n      return\n    end\n"
        "    local.get $o\n    i32.const 10\n    i32.sub\n    i32.load\n    local.set $nx\n"
        "    local.get $s\n    i32.const 8\n    i32.sub\n"
        "    local.get $o\n    i32.const 10\n    i32.sub\n    i32.store\n"
        "    local.get $s\n    i32.const 4\n    i32.sub\n    local.get $nx\n    i32.store\n"
        "    local.get $nx\n"
        "    if\n"
        "      local.get $nx\n      i32.const 8\n      i32.sub\n"
        "      local.get $s\n      i32.const 4\n      i32.sub\n      i32.store\n"
        "    end\n"
        "    local.get $o\n    i32.const 10\n    i32.sub\n    local.get $s\n    i32.store\n  )\n",
        rtExp(String.withCString("_xtc_weak_register")).cString());
        out.appendCString(
        "  (func $_xtc_weak_load (param $s i32) (result i32)\n"
        "    local.get $s\n    i32.load\n  )\n"
        "  (func $_xtc_weak_zero_for (param $o i32)\n"
        "    (local $s i32) (local $nx i32)\n"
        "    local.get $o\n    i32.const 10\n    i32.sub\n    i32.load\n    local.set $s\n"
        "    block $done\n    loop $w\n"
        "    local.get $s\n    i32.eqz\n    br_if $done\n"
        "    local.get $s\n    i32.const 4\n    i32.sub\n    i32.load\n    local.set $nx\n"
        "    local.get $s\n    i32.const 0\n    i32.store\n"
        "    local.get $s\n    i32.const 8\n    i32.sub\n    i32.const 0\n    i32.store\n"
        "    local.get $s\n    i32.const 4\n    i32.sub\n    i32.const 0\n    i32.store\n"
        "    local.get $nx\n    local.set $s\n"
        "    br $w\n    end\n    end\n"
        "    local.get $o\n    i32.const 10\n    i32.sub\n    i32.const 0\n    i32.store\n  )\n");

        out.appendFormat(
        "  (func $_xtc_dealloc%s (param $o i32)\n"
        "    (local $base i32) (local $stride i32) (local $count i32) (local $d i32)\n"
        "    (local $q i32) (local $i i32)\n"
        "    local.get $o\n    call $_xtc_weak_zero_for\n"
        "    local.get $o\n    i32.const 38\n    i32.sub\n    local.set $base\n"
        "    local.get $base\n    i32.const 4\n    i32.add\n    i32.load\n    local.set $stride\n"
        "    local.get $base\n    i32.const 12\n    i32.add\n    i32.load\n    local.set $count\n"
        "    local.get $base\n    i32.const 20\n    i32.add\n    i32.load\n    local.set $d\n"
        "    local.get $d\n"
        "    if\n"
        "      local.get $o\n      i32.const 2\n      i32.sub\n"
        "      i32.const 32768\n      i32.store16\n"
        "      local.get $o\n      local.set $q\n"
        "      i32.const 0\n      local.set $i\n"
        "      block $done\n      loop $each\n"
        "      local.get $i\n      local.get $count\n      i32.ge_u\n      br_if $done\n",
        rtExp(String.withCString("_xtc_dealloc")).cString());
        out.appendFormat(
        "      local.get $q\n      local.get $d\n      call_indirect (type $%s)\n",
        deallocTy.cString());
        out.appendCString(
        "      local.get $q\n      local.get $stride\n      i32.add\n      local.set $q\n"
        "      local.get $i\n      i32.const 1\n      i32.add\n      local.set $i\n"
        "      br $each\n      end\n      end\n"
        "    end\n"
        "    local.get $base\n    call $_xtc_free\n  )\n");

        if (hasSuffix(String.withCString("__count__"))) {
            out.appendFormat(
            "  (func $_xtc_count%s (param $p i32) (result i32)\n"
            "    local.get $p\n    i32.const 1048576\n    i32.lt_u\n"
            "    if\n      i32.const 0\n      return\n    end\n"
            "    local.get $p\n    i32.const 26\n    i32.sub\n    i32.load\n  )\n",
            rtExp(String.withCString("_xtc_count")).cString());
        }
        Array* sfx = Wasm32.sorted(_newSuffixes);
        for (u32 i = (u32)0; i < sfx.count(); i = i + (u32)1) {
            String* suffix = (String*)sfx.get(i);
            if (suffix.equals(String.withCString("__count__"))) continue;
            u32 w = Wasm32.newWidth(suffix);
            if (w != (u32)0) {
                out.appendFormat(
                "  (func $_xtc_new_%s (param $n i32) (result i32)\n", suffix.cString());
                out.appendFormat(
                "    local.get $n\n    i32.const %lu\n    i32.const 0\n    call $_xtc_alloc\n  )\n",
                w);
            } else {
                String* dn = String.withString(suffix);
                dn.appendCString("$dealloc");
                Number* de = (Number*)_fnTableIndex.get((Hashable*)dn);
                if (de == 0 && _linkLibs) {
                    // `new C[N]` of an IMPORTED class: the descriptor is the
                    // library method's slot in the app's table.
                    IRSymbol* ext = symbolNamed(dn);
                    if (ext != 0 && ext.isFunc())
                        de = Number.with(ensureImportedFnSlot(ext));
                }
                out.appendFormat(
                "  (func $_xtc_new_%s (param $c i32) (param $s i32) (result i32)\n",
                suffix.cString());
                out.appendFormat(
                "    local.get $c\n    local.get $s\n    i32.const %lu\n    call $_xtc_alloc\n  )\n",
                de == 0 ? (u32)0 : de.asU32());
            }
        }
    }

    // The primitive-suffix widths of the _xtc_new_<T> family; 0 = a class.
    static u32 newWidth(String* s)
    {
        if (s.equals(String.withCString("u8")) || s.equals(String.withCString("i8"))
         || s.equals(String.withCString("bool"))) return (u32)1;
        if (s.equals(String.withCString("u16")) || s.equals(String.withCString("i16")))
            return (u32)2;
        if (s.equals(String.withCString("u32")) || s.equals(String.withCString("i32"))
         || s.equals(String.withCString("float")) || s.equals(String.withCString("pointer"))
         || s.equals(String.withCString("string"))) return (u32)4;
        if (s.equals(String.withCString("u64")) || s.equals(String.withCString("i64"))
         || s.equals(String.withCString("double"))) return (u32)8;
        return (u32)0;
    }
}
