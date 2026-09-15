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

    // XTType.widenType:with:, rule for rule.
    static String* widen(String* a, String* b)
        {
        if (a == 0)
            return b;
        if (b == 0)
            return a;
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
    // `inferTypeFromLiteral` (visitLiteralInt), ladder for ladder.
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
