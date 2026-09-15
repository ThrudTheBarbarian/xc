// Overload.xc — which of several same-named declarations a call means.
// =================================================================
//
// self-hosting M6. The port of `-[XTSemanticAnalyzer conversionRankFrom:to:…]`
// and the scoring around it. Every rank below is transcribed, including the
// ones that only make sense once you know what they are protecting:
//
//   * NARROWING is allowed and ranked by how much is lost, so `u32 → u16` beats
//     `u32 → u8`. Arithmetic is promoted to 32 bits (see Sema.typeBinary), so
//     without this every call passing `a - b` to a u16 parameter would fail to
//     resolve — `Math.rand(hi - lo)` is exactly that shape.
//   * Integer→float sits BELOW integer narrowing, so an integer argument with
//     both an int and a float overload available picks the int one.
//   * An integer LITERAL is ranked by the width of the parameter it fits, so
//     the smallest fitting overload wins rather than the first one seen.
//
// Lower is better; NO_MATCH means no conversion exists. Autoboxing (rank 8) and
// unboxing (rank 9) are not implemented — a call needing them scores NO_MATCH
// and the analyser declines to stamp it, which shows up in the harness as a
// missing annotation rather than as a wrong one.

#import "Foundation.xc"
#import "Types.xc"

class Overload
    {
    u8 _unused;
    void init(void)
        {
        _unused = (u8)0;
        }

    // className -> parent name, so a class-pointer argument can be ranked
    // against a class-pointer parameter: exact is 0, an UPCAST is 1, and
    // unrelated classes do not convert at all. Without it every call taking a
    // base-class parameter looked unresolvable.
    static Map* _parents;
    // className -> a comma-joined list of the protocols it conforms to,
    // inherited ones included. A class argument satisfies a protocol
    // parameter, which is how `render(Drawable@)` takes a Sprite.
    static Map* _conforms;
    static void setHierarchy(Map* parents, Map* conforms)
        {
        _parents = parents;
        _conforms = conforms;
        }

    static bool conformsTo(String* cls, String* proto)
        {
        if (_conforms == 0 || cls == 0 || proto == 0)
            return false;
        String* list = (String*)_conforms.get((Hashable*)cls);
        if (list == 0)
            return false;
        Array* names = list.splitOnByte((u8)',');
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            if (((String*)names.get(i)).trimmed().equals(proto))
                return true;
        return false;
        }

    static bool descendsFrom(String* sub, String* sup)
        {
        if (sub == 0 || sup == 0)
            return false;
        String* c = sub;
        u32 guard = (u32)0;
        while (c != 0 && guard < (u32)64)
            {
            if (c.equals(sup))
                return true;
            if (_parents == 0)
                return false;
            c = (String*)_parents.get((Hashable*)c);
            guard = guard + (u32)1;
            }
        return false;
        }

    static u32 noMatch(void)
        {
        return (u32)$FFFFFFFF;
        }

    static u32 rank(String* argSpelling, String* par, bool isIntLit, i64 litValue)
        {
        if (argSpelling == 0 || par == 0)
            return Overload.noMatch();
        // An ARRAY argument decays to a pointer to its element — `u16 buf[8]`
        // satisfies a `u16@` parameter, which is how every buffer is passed.
        // Placement qualifiers are not part of a parameter's identity —
        // `banked:u8@` and `u8@` are the same type to a call.
        String* arg = Overload._decay(Overload._unqualify(argSpelling));
        String* parc = Overload._unqualify(par);
        if (arg.equals(parc))
            return (u32)0;

        // Pointers: identical pointees are exact; a void pointee on either side
        // is the loose match the original gives rank 5.
        if (Types.isPointer(arg) && Types.isPointer(parc))
            {
            String* a = Overload._pointee(arg);
            String* b = Overload._pointee(parc);
            if (a.equals(b))
                return (u32)0;
            if (Overload._is(a, "void") || Overload._is(b, "void"))
                return (u32)5;
            // An UPCAST converts — `Dog@` satisfies an `Animal@` parameter —
            // and ranks below an exact match so exactness still wins.
            if (Overload.descendsFrom(a, b))
                return (u32)1;
            // A class satisfies a PROTOCOL parameter when it conforms.
            if (Overload.conformsTo(a, b))
                return (u32)1;
            return Overload.noMatch();
            }
        if (Types.isPointer(arg) != Types.isPointer(parc))
            return Overload.noMatch();

        if (Overload._is(arg, "bool") && (Overload._is(parc, "u8") || Overload._is(parc, "i8")))
            return (u32)1;

        // An integer argument into an ENUM-typed parameter (mirror of the
        // original's XTTypeKindEnum arm): an enum constant resolves as u8 —
        // that is how the members register — so u8 converts at rank 1, and an
        // in-range literal likewise. Wider integers still need a cast.
        if (Types.isEnumName(parc))
            {
            if (Overload._is(arg, "u8"))
                return (u32)1;
            if (isIntLit && litValue >= (i64)0 && litValue <= (i64)255)
                return (u32)1;
            }
        if (Types.isEnumName(arg) &&
            (Overload._is(parc, "u8") || Overload._is(parc, "u16") ||
             Overload._is(parc, "i8") || Overload._is(parc, "i16") ||
             Overload._is(parc, "i32")))
            return (u32)1;

        // An integer literal fits any integer type big enough, ranked by that
        // type's width so the smallest fitting parameter wins.
        if (isIntLit && Types.isInteger(parc))
            {
            u32 w = Types.byteWidth(parc);
            bool ps = Types.isSigned(parc);
            if (w == (u32)1)
                {
                if (ps && litValue >= (i64)-128 && litValue <= (i64)127)
                    return (u32)1;
                if (!ps && litValue >= (i64)0 && litValue <= (i64)255)
                    return (u32)1;
                }
            else if (w == (u32)2)
                {
                if (ps && litValue >= (i64)-32768 && litValue <= (i64)32767)
                    return (u32)2;
                if (!ps && litValue >= (i64)0 && litValue <= (i64)65535)
                    return (u32)2;
                }
            else if (w == (u32)4)
                {
                if (ps)
                    return (u32)3;
                // The upper bound is load-bearing now and was not before: with
                // an i32 payload every non-negative value fitted a u32 by
                // construction, so the check the original writes
                // (`litValue <= 0xFFFFFFFFLL`) was invisible here.
                if (litValue >= (i64)0 && litValue <= (i64)4294967295)
                    return (u32)3;
                }
            }
        if (isIntLit && Overload._is(parc, "float"))
            return (u32)4;
        if (isIntLit && Overload._is(parc, "double"))
            return (u32)5;

        bool ai = Types.isInteger(arg);
        bool pi = Types.isInteger(parc);
        if (ai && pi)
            {
            u32 aw = Types.byteWidth(arg);
            u32 pw = Types.byteWidth(par);
            bool as = Types.isSigned(arg);
            bool ps = Types.isSigned(par);
            if (pw >= aw)
                {
                if (as == ps)
                    return (u32)2; // lossless widening
                if (!as && ps && pw > aw)
                    return (u32)3;         // u→i, strictly wider
                return Overload.noMatch(); // i→u needs the value
                }
            return (u32)2 + (aw - pw); // narrowing, least first
            }
        if (ai && Overload._is(parc, "float"))
            return (u32)6;
        if (ai && Overload._is(parc, "double"))
            return (u32)7;
        if (Overload._is(arg, "float") && Overload._is(parc, "double"))
            return (u32)3;

        return Overload.noMatch();
        }

    // A candidate's score is its WORST parameter — one impossible argument
    // rules the whole candidate out.
    static u32 worstOf(u32 a, u32 b)
        {
        if (a == Overload.noMatch() || b == Overload.noMatch())
            return Overload.noMatch();
        return (a > b) ? a : b;
        }

    static String* _unqualify(String* t)
        {
        String* s = t;
        while (true)
            {
            u32 c = (u32)$FFFFFFFF;
            for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
                if (s.byteAt(i) == (u8)':')
                    c = i;
            if (c == (u32)$FFFFFFFF)
                return s;
            s = s.substringBytes(c + (u32)1, s.byteLength() - c - (u32)1);
            }
        return s;
        }

    static String* _decay(String* t)
        {
        for (u32 i = (u32)0; i < t.byteLength(); i = i + (u32)1)
            {
            if (t.byteAt(i) == (u8)'[')
                {
                String* e = t.substringBytes((u32)0, i);
                e.appendByte((u8)'*');
                return e;
                }
            }
        return t;
        }

    static String* _pointee(String* t)
        {
        if (t.byteLength() > (u32)0 && t.byteAt(t.byteLength() - (u32)1) == (u8)'*')
            return t.substringBytes((u32)0, t.byteLength() - (u32)1);
        if (Overload._is(t, "string"))
            return String.withCString("u8");
        return t;
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
