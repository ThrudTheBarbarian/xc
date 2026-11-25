// Types.xc — the facts the analyser needs about a type spelling.
// =================================================================
//
// self-hosting M6. The port of the parts of src/xtc/types/XTType.m the analyser
// actually asks about: is this an integer, is it signed, how wide is it, and
// what comes out when two of them meet in an expression.
//
// It answers from the SPELLING rather than from a type object, for the reason
// given in Sema.xc: the oracle prints displayName, so the spelling is what has
// to match, and every rule below is decidable from it. `u8@` is a pointer
// because it ends in `@`, `Foo` is a class because the class table says so —
// the two callers that need that distinction pass it in.
//
// The widening rule is XTType.widenType:with:, transcribed. It is not the
// obvious "widest wins": a pointer plus an integer stays a POINTER (collapsing
// it to a scalar by byte width lost the pointee and mis-sized the deref), and
// signedness is decided across BOTH operands before the width is applied.

#import "Foundation.xc"
#import <FloatEncoding>

class Types
    {
    u8 _unused;
    void init(void)
        {
        _unused = (u8)0;
        }

    // Enum type names, registered by sema as declarations are collected. The
    // original's type table holds an XTEnumType (byteWidth 1, unsigned); this
    // string world needs the same answer for `StrEncoding` or the widening of
    // `enc == ENC_UTF8` flips: byteWidth 0 lost the equal-width tie to u8 and
    // 150 sema dumps said ty=u8 where the original says ty=StrEncoding.
    static Map* _enumReg;
    static void noteEnum(String* name)
        {
        if (_enumReg == (Map*)0)
            _enumReg = new Map();
        _enumReg.set((Hashable*)name, (Object*)name);
        }
    static bool isEnumName(String* t)
        {
        if (t == 0 || _enumReg == (Map*)0)
            return false;
        return _enumReg.get((Hashable*)t) != (Object*)0;
        }

    static bool isPointer(String* t)
        {
        if (t == 0 || t.byteLength() == (u32)0)
            return false;
        if (t.byteAt(t.byteLength() - (u32)1) == (u8)'*')
            return true;
        return Types._is(t, "pointer") || Types._is(t, "string");
        }

    static bool isFloating(String* t)
        {
        return Types._is(t, "float") || Types._is(t, "double");
        }

    // A 16-bit float: f16 (IEEE binary16, pack e5m10) or bf16 (pack e8m7).
    // Neither an integer nor floating: its value is a bit pattern, converted
    // through f32 for every operation (FloatPack.xc). XTType.isFloatPack.
    static bool isPack(String* t)
        {
        return Types._is(t, "f16") || Types._is(t, "bf16");
        }

    // The pack's exponent and mantissa widths.
    static u32 packExp(String* t)
        {
        return Types._is(t, "bf16") ? 8 : 5;
        }
    static u32 packMant(String* t)
        {
        return Types._is(t, "bf16") ? 7 : 10;
        }

    // The bits of a literal's double: a float literal's digits, or an integer
    // literal's value, read as the reference reads them (strtod, a (double)
    // conversion), negated when asked.
    static u64 literalBits(bool isFloat, String* text, i64 num, bool negate)
        {
        Data* d = (Data*)0;
        if (isFloat)
            {
            String* t = text;
            if (negate)
                {
                t = String.withCString("-");
                t.append(text);
                }
            d = FloatEncoding.ieeeBytes(t, true);
            }
        else
            d = FloatEncoding.ieeeBytes(String.withI64(negate ? 0 - num : num), true);
        u64 bits = 0;
        for (u32 i = 8; i > 0; i--)
            bits = (bits << 8) | (u64)d.byteAt(i - 1);
        return bits;
        }

    // A double, given as its bits, rounded to a pack: FloatPack.xc's
    // _xt_fpk_pack_f64, the same steps. XTType.packBitsForDouble:.
    static u32 packBits(u64 x, u32 e, u32 m)
        {
        u32 one = 1;
        u32 hi = (u32)(x >> 32);
        u32 lo = (u32)x;
        u32 sign = hi >> 31;
        u32 ex = (hi >> 20) & (u32)0x7FF;
        u32 mhi = hi & (u32)0xFFFFF;
        u32 sig = (mhi << 11) | (lo >> 21);
        if ((lo & (u32)0x1FFFFF) != 0)
            sig = sig | one;
        u32 inf = ((one << e) - one) << m;
        if (ex == (u32)0x7FF)
            {
            if (mhi == 0 && lo == 0)
                return (sign << (e + m)) | inf;
            u32 top = (sig << 1) | one;
            return (sign << (e + m)) | inf | (one << (m - one)) | (top >> (32 - m));
            }
        if (ex == 0 && mhi == 0 && lo == 0)
            return sign << (e + m);
        i32 unb = ex == 0 ? -1022 : (i32)ex - 1023;
        if (ex != 0)
            sig = sig | (u32)0x80000000;
        i32 bias = (i32)((one << (e - one)) - one);
        i32 te = unb + bias;
        i32 sh = 31 - (i32)m;
        if (te < 1)
            {
            sh = sh + 1 - te;
            te = 1;
            }
        u32 q = 0;
        if (sh == 32)
            {
            if (sig > (u32)0x80000000)
                q = 1;
            }
        else if (sh < 32)
            {
            u32 us = (u32)sh;
            q = sig >> us;
            u32 rem = sig & ((one << us) - one);
            u32 half = one << (us - one);
            if (rem > half || (rem == half && (q & one) != 0))
                q = q + one;
            }
        u32 bits = ((u32)(te - 1) << m) + q;
        if (bits > inf)
            bits = inf;
        return (sign << (e + m)) | bits;
        }

    // Can a value of `from` reach a slot of `to` with no cast? Only when every
    // value converts exactly: a pack to itself, f32 or f64. An integer reaches
    // a pack through a cast. XTType.packConvertsImplicitly:to:.
    static bool packConvertsImplicitly(String* from, String* to)
        {
        if (from == 0 || to == 0)
            return true;
        if (Types.isPack(to))
            return from.equals(to);
        if (Types.isPack(from))
            return Types.isFloating(to);
        return true;
        }

    static bool isInteger(String* t)
        {
        if (t == 0)
            return false;
        if (Types.isPointer(t) || Types.isFloating(t))
            return false;
        return Types._is(t, "i8") || Types._is(t, "u8") || Types._is(t, "i16") || Types._is(t, "u16") || Types._is(t, "i32") || Types._is(t, "u32") || Types._is(t, "i64") || Types._is(t, "u64") || Types._is(t, "bool");
        }

    static bool isSigned(String* t)
        {
        return Types._is(t, "i8") || Types._is(t, "i16") || Types._is(t, "i32") || Types._is(t, "i64");
        }

    // Byte widths as the FRONT END sees them, which is what sema reasons with.
    // The pinned oracle configuration is 8-byte pointers and 4-byte IEEE float
    // (see --dump-sema); a backend's own widths are not this question.
    static u32 byteWidth(String* t)
        {
        if (t == 0)
            return (u32)0;
        if (Types.isPointer(t))
            return (u32)8;
        if (Types._is(t, "double"))
            return (u32)8;
        if (Types._is(t, "float"))
            return (u32)4;
        if (Types.isPack(t))
            return 2;
        if (Types._is(t, "bool"))
            return (u32)1;
        if (Types._is(t, "i8"))
            return (u32)1;
        if (Types._is(t, "u8"))
            return (u32)1;
        if (Types._is(t, "i16"))
            return (u32)2;
        if (Types._is(t, "u16"))
            return (u32)2;
        if (Types._is(t, "i32"))
            return (u32)4;
        if (Types._is(t, "u32"))
            return (u32)4;
        if (Types._is(t, "i64"))
            return (u32)8;
        if (Types._is(t, "u64"))
            return (u32)8;
        if (Types.isEnumName(t))
            return (u32)1; // enum: one unsigned byte
        return (u32)0;     // named type: the class table knows
        }

    static String* signedOfWidth(u32 w)
        {
        if (w == (u32)1)
            return String.withCString("i8");
        if (w == (u32)2)
            return String.withCString("i16");
        if (w == (u32)8)
            return String.withCString("i64");
        return String.withCString("i32");
        }

    // An ARRAY operand of `+` or `-` decays to a pointer to its element, as a
    // C array does: `b + 1` is `&b[1]` and `b - p` is a pointer difference.
    // Without this the array met the integer in widen() as a type it has no
    // width for, the sum took the integer's type, and the array's address was
    // added as a narrow integer (#516). One dimension only, where the element
    // is not itself an array; the other operand must be an integer, a pointer
    // or such an array. Anything else comes back unchanged.
    // XTType.arithmeticDecay:other:, rule for rule.
    static String* arithmeticDecay(String* t, String* other)
        {
        if (!Types._oneDimArray(t) || other == 0)
            return t;
        if (!Types.isInteger(other) && !Types.isEnumName(other) && !Types.isPointer(other) && !Types._oneDimArray(other))
            return t;
        String* p = t.substringBytes((u32)0, t.lastIndexOfByte((u8)'['));
        p.appendByte((u8)'*');
        return p;
        }

    // An array whose element is not itself an array: the spelling ends in
    // `]`, and what comes before its last `[` does not.
    static bool _oneDimArray(String* t)
        {
        if (t == 0 || t.byteLength() == (u32)0 || t.byteAt(t.byteLength() - (u32)1) != (u8)']')
            return false;
        u32 at = t.lastIndexOfByte((u8)'[');
        if (at == String.notFound() || at == (u32)0)
            return false;
        return t.byteAt(at - (u32)1) != (u8)']';
        }

    // XTType.widenType:with:, rule for rule.
    static String* widen(String* a, String* b)
        {
        if (a == 0)
            return b;
        if (b == 0)
            return a;
        // A 16-bit float widens to the type that holds both operands; two
        // different packs have no common type (sema refuses them).
        if (Types.isPack(a) || Types.isPack(b))
            {
            String* p = Types.isPack(a) ? a : b;
            String* o = Types.isPack(a) ? b : a;
            if (Types._is(o, "double"))
                return String.withCString("double");
            if (Types._is(o, "float") || (Types.isPack(o) && !o.equals(p)))
                return String.withCString("float");
            if (Types.isPack(o) || Types._is(o, "u8") || Types._is(o, "i8") || Types._is(o, "bool")
                || Types.isEnumName(o))
                return p;
            if (Types.isInteger(o) && Types.byteWidth(o) <= 2)
                return String.withCString("float");
            if (Types.isInteger(o))
                return String.withCString("double");
            return p;
            }
        if (Types._is(a, "double") || Types._is(b, "double"))
            return String.withCString("double");
        if (Types.isFloating(a) || Types.isFloating(b))
            return String.withCString("float");
        // A pointer meeting an integer stays the pointer — pointer arithmetic.
        if (Types.isPointer(a) && Types.isInteger(b))
            return a;
        if (Types.isPointer(b) && Types.isInteger(a))
            return b;
        // A FUNCTION type meeting an integer stays the function type: the
        // original's widen compares byte widths there (a function type is
        // pointer-wide, unsigned) and hands back the function type. Only
        // erroneous expressions reach this — a typedef name used as a value —
        // but the dumps must agree on those too (task #36).
        if (a.indexOfByte((u8)'(') != String.notFound() && Types.isInteger(b))
            return a;
        if (b.indexOfByte((u8)'(') != String.notFound() && Types.isInteger(a))
            return b;

        u32 wa = Types.byteWidth(a);
        u32 wb = Types.byteWidth(b);
        bool anySigned = Types.isSigned(a) || Types.isSigned(b);
        u32 wmax = (wa >= wb) ? wa : wb;
        if (wa >= wb)
            {
            if (anySigned)
                return Types.signedOfWidth(wmax);
            return a;
            }
        if (anySigned)
            return Types.signedOfWidth(wmax);
        return b;
        }

    // The narrowest type that holds a value — the analyser's
    // `visitLiteralInt`, ladder for ladder. This types a LITERAL WRITTEN IN
    // THE SOURCE, so it reaches u64/i64: `5000000000` is a u64.
    //
    // This used to be TWO doors, because the payload was an i32: a literal that
    // arrived negative could only be a large positive that had overflowed into
    // the sign bit, so `$DEADBEEF` had to be forced back to u32, while a
    // negative from constant FOLDING was genuinely negative. With a 64-bit
    // payload the distinction evaporates — both spellings now hold the value
    // the source meant — and the original never had two doors to begin with.
    static String* forIntLiteral(i64 v)
        {
        return Types.forValue(v);
        }

    static String* forValue(i64 v)
        {
        if (v >= (i64)0)
            {
            if (v <= (i64)255)
                return String.withCString("u8");
            if (v <= (i64)65535)
                return String.withCString("u16");
            if (v <= (i64)4294967295)
                return String.withCString("u32");
            // Too wide for 32 bits: 64-bit rather than a silent wrap.
            return String.withCString("u64");
            }
        if (v >= (i64)-128)
            return String.withCString("i8");
        if (v >= (i64)-32768)
            return String.withCString("i16");
        if (v >= (i64)-2147483648)
            return String.withCString("i32");
        return String.withCString("i64");
        }

    // The analyser's OTHER integer ladder: `inferTypeFromLiteral:`, which types
    // the RESULT of a constant FOLD (and an `auto` declaration's initialiser).
    // It is the same ladder as forIntLiteral except that it STOPS AT 32 BITS —
    // a folded `1000000 * 1000000` is a u32 even though the value needs 40
    // bits, because the fold's type came from a 32-bit rung and nothing above
    // it exists. The VALUE is still carried in full (bug 198: the fold is done
    // in 64 bits); only the type it lands on is capped, which is what keeps
    // the two compilers' trees byte-identical.
    static String* forFoldedValue(i64 v)
        {
        if (v >= (i64)0)
            {
            if (v <= (i64)255)
                return String.withCString("u8");
            if (v <= (i64)65535)
                return String.withCString("u16");
            return String.withCString("u32");
            }
        if (v >= (i64)-128)
            return String.withCString("i8");
        if (v >= (i64)-32768)
            return String.withCString("i16");
        return String.withCString("i32");
        }

    static bool _is(String* s, string lit)
        {
        if (s == 0)
            return false;
        u32 i = (u32)0;
        while (lit[i] != (u8)0)
            {
            if (i >= s.byteLength())
                return false;
            if (s.byteAt(i) != lit[i])
                return false;
            i = i + (u32)1;
            }
        return i == s.byteLength();
        }
    }
