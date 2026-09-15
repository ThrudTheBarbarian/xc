// Mangle.xc — the symbol names the rest of the compiler agrees on.
// =================================================================
//
// self-hosting M6. The port of `+[XTLabelGenerator mangleName:paramTypes:]` and
// its type-suffix table. This is the first thing the analyser does and the
// smallest thing it can be wrong about with the widest blast radius: a mangled
// name is what a call site resolves TO, what the linker sees, and what a
// library's interface publishes. One wrong suffix and two overloads collide
// silently.
//
//   foo(u16, u8@)      -> foo__u16_pu8      … wait, no: `u8@` is `s`
//   foo(u16, string)   -> foo__u16_s
//   foo(void)          -> foo__v
//   PI() -> float      -> PI__v_f           (zero-arg: return type disambiguates)
//
// The original works from XTType objects; this works from the type SPELLINGS
// the parser recorded, which is the same information written down differently.
// Every rule below is transcribed from XTLabelGenerator.m — where it looks
// arbitrary (`u8@` is `s`, not `pu8`) it is arbitrary there too, and copying
// the arbitrariness IS the job.

#import "Foundation.xc"
#import "Types.xc"

class Mangle
    {
    u8 _unused;
    void init(void)
        {
        _unused = (u8)0;
        }

    // A named type's suffix depends on what KIND of thing the name is —
    // `C<name>` for a class, `S<name>` for a struct, `e<name>` for an enum —
    // so the tables have to be reachable from here. Static ivars (Task #831)
    // are exactly the right shape for it: one copy for the class, set once
    // before any mangling happens.
    static Map* _classNames;
    static Map* _structNames;

    static void setTables(Map* classes, Map* structs)
        {
        _classNames = classes;
        _structNames = structs;
        }

    // The one-token suffix for a type spelling. Qualifiers (`main:`, `weak:`,
    // `banked:`) are placement, not identity, and never reach the suffix.
    static String* suffix(String* spelling)
        {
        if (spelling == 0)
            return String.withCString("v");
        String* t = Mangle._stripQualifiers(spelling);

        // Pointer: strip ONE trailing `@` and recurse. `u8@` is spelled `s`
        // because xtc calls it `string`; every other pointee is `p<suffix>`.
        if (t.byteLength() > (u32)0 && t.byteAt(t.byteLength() - (u32)1) == (u8)'*')
            {
            String* pointee = t.substringBytes((u32)0, t.byteLength() - (u32)1);
            if (Mangle._is(pointee, "u8"))
                return String.withCString("s");
            String* out = String.withCString("p");
            out.append(Mangle.suffix(pointee));
            return out;
            }
        // Array: `T[N]` mangles as `a<suffix of T>` — the count is not part of
        // the identity.
        u32 br = Mangle._indexOfChar(t, (u8)'[');
        if (br != (u32)$FFFFFFFF)
            {
            String* out = String.withCString("a");
            out.append(Mangle.suffix(t.substringBytes((u32)0, br)));
            return out;
            }

        if (Mangle._is(t, "void"))
            return String.withCString("v");
        if (Mangle._is(t, "bool"))
            return String.withCString("b");
        if (Mangle._is(t, "i8"))
            return String.withCString("i8");
        if (Mangle._is(t, "u8"))
            return String.withCString("u8");
        if (Mangle._is(t, "i16"))
            return String.withCString("i16");
        if (Mangle._is(t, "u16"))
            return String.withCString("u16");
        if (Mangle._is(t, "i32"))
            return String.withCString("i32");
        if (Mangle._is(t, "u32"))
            return String.withCString("u32");
        if (Mangle._is(t, "i64"))
            return String.withCString("i64");
        if (Mangle._is(t, "u64"))
            return String.withCString("u64");
        if (Mangle._is(t, "float"))
            return String.withCString("f");
        if (Mangle._is(t, "double"))
            return String.withCString("double");
        if (Mangle._is(t, "pointer"))
            return String.withCString("p");
        if (Mangle._is(t, "string"))
            return String.withCString("s");
        // A named type — class, struct or enum, and the mangling says which:
        // `Object@` is `pCObject`, not `pObject`.
        if (_classNames != 0 && _classNames.get((Hashable*)t) != 0)
            {
            String* out = String.withCString("C");
            out.append(t);
            return out;
            }
        if (_structNames != 0 && _structNames.get((Hashable*)t) != 0)
            {
            String* out = String.withCString("S");
            out.append(t);
            return out;
            }
        if (Types.isEnumName(t))
            {
            String* out = String.withCString("e");
            out.append(t);
            return out;
            }
        // Unknown name: the display name, exactly as the original's `default:`.
        return t;
        }

    // `base__suffix_suffix…`, or `base__v` for no parameters. A zero-arg
    // function with a known return type appends it: `PI__v_f` and `PI__v_double`
    // are different functions.
    static String* name(String* base, Array* paramSpellings, String* returnSpelling)
        {
        String* out = String.withString(base);
        if (paramSpellings == 0 || paramSpellings.count() == (u32)0)
            {
            out.appendCString("__v");
            if (returnSpelling != 0)
                {
                out.appendByte((u8)'_');
                out.append(Mangle.suffix(returnSpelling));
                }
            return out;
            }
        out.appendCString("__");
        for (u32 i = (u32)0; i < paramSpellings.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                out.appendByte((u8)'_');
            out.append(Mangle.suffix((String*)paramSpellings.get(i)));
            }
        return out;
        }

    // `main:`, `weak:`, `banked:`, `shadow:`, `raw:`, `outlet:` — any run of
    // them, colon-separated, in front of the type proper.
    static String* _stripQualifiers(String* s)
        {
        String* t = s;
        while (true)
            {
            u32 c = Mangle._indexOfChar(t, (u8)':');
            if (c == (u32)$FFFFFFFF)
                return t;
            t = t.substringBytes(c + (u32)1, t.byteLength() - c - (u32)1);
            }
        return t;
        }

    static u32 _indexOfChar(String* s, u8 ch)
        {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            if (s.byteAt(i) == ch)
                return i;
        return (u32)$FFFFFFFF;
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
