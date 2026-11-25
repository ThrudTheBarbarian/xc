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

    // A small float, one width in one pack: f16 (IEEE binary16, pack e5m10),
    // bf16 (pack e8m7), f8 (OCP E4M3), and every other pack by its canonical
    // name: `fW$eXmY`, with `$kind` when the kind is not the split's default
    // (finite for f8's e4m3, ieee for every other), and `f8$ue8m0`, the
    // unsigned scale. No source can spell such a name, it holds no `:` (which
    // begins a qualifier in a spelling, stripQual), and a diagnostic writes it
    // as the source does (packSpelling). Neither an integer nor floating:
    // its value is a bit pattern, converted through f32 for every operation
    // (FloatPack.xc). XTType.isFloatPack, and the pack model below is
    // XTType.m's, step for step.
    //
    // packDesc: 0 for no pack, else 0x80000000 | unsigned << 28 | kind << 24
    // | width << 16 | exponent bits << 8 | mantissa bits.
    static u32 packDesc(String* t)
        {
        if (t == 0 || t.byteLength() < (u32)2)
            return 0;
        u8 c0 = t.byteAt(0);
        if (c0 != (u8)'f' && c0 != (u8)'b')
            return 0;
        if (Types._is(t, "f16"))
            return Types.packDescOf(16, 5, 10, 0, false);
        if (Types._is(t, "bf16"))
            return Types.packDescOf(16, 8, 7, 0, false);
        if (Types._is(t, "f8"))
            return Types.packDescOf(8, 4, 3, 1, false);
        u32 w = 0;
        u32 at = 0;
        if (t.hasPrefix(String.withCString("f8$")))
            {
            w = 8;
            at = 3;
            }
        else if (t.hasPrefix(String.withCString("f16$")))
            {
            w = 16;
            at = 4;
            }
        else
            return 0;
        String* rest = t.substringFromByte(at);
        String* split = rest;
        String* kw = (String*)0;
        u32 dollar = rest.byteIndexOf(String.withCString("$"));
        if (dollar != String.notFound())
            {
            split = rest.substringBytes(0, dollar);
            kw = rest.substringFromByte(dollar + 1);
            }
        u32 sd = Types.packSplit(split);
        if (sd == 0)
            return 0;
        u32 e = (sd >> 8) & (u32)0xFF;
        u32 m = sd & (u32)0xFF;
        bool uns = (sd & (u32)0x10000000) != 0;
        if (uns)
            {
            if (kw != (String*)0 || w != 8 || e != 8 || m != 0)
                return 0;
            return Types.packDescOf(8, 8, 0, 1, true);
            }
        if (e + m + 1 != w)
            return 0;
        u32 kind = Types.packDefaultKind(w, e, m);
        if (kw != (String*)0)
            {
            if (Types._is(kw, "ieee"))
                kind = 0;
            else if (Types._is(kw, "finite"))
                kind = 1;
            else if (Types._is(kw, "none"))
                kind = 2;
            else
                return 0;
            }
        if (!Types.packCanonical(w, e, m, kind, false).equals(t))
            return 0;
        return Types.packDescOf(w, e, m, kind, false);
        }

    static u32 packDescOf(u32 w, u32 e, u32 m, u32 kind, bool uns)
        {
        u32 d = (u32)0x80000000 | (kind << 24) | (w << 16) | (e << 8) | m;
        if (uns)
            d = d | (u32)0x10000000;
        return d;
        }

    // "eXmY" (or "ueXmY") as 0x80000000 | unsigned << 28 | X << 8 | Y; 0 for
    // any other spelling.
    static u32 packSplit(String* pk)
        {
        u32 n = pk.byteLength();
        u32 i = 0;
        bool uns = false;
        if (i < n && pk.byteAt(i) == (u8)'u')
            {
            uns = true;
            i++;
            }
        if (i + 1 >= n || pk.byteAt(i) != (u8)'e' || !Types.isDigit(pk.byteAt(i + 1)))
            return 0;
        i++;
        u32 a = 0;
        while (i < n && Types.isDigit(pk.byteAt(i)) && a < 1000)
            {
            a = a * 10 + (u32)(pk.byteAt(i) - (u8)'0');
            i++;
            }
        if (i + 1 >= n || pk.byteAt(i) != (u8)'m' || !Types.isDigit(pk.byteAt(i + 1)))
            return 0;
        i++;
        u32 b = 0;
        while (i < n && Types.isDigit(pk.byteAt(i)) && b < 1000)
            {
            b = b * 10 + (u32)(pk.byteAt(i) - (u8)'0');
            i++;
            }
        if (i != n || a > 255 || b > 255)
            return 0;
        u32 d = (u32)0x80000000 | (a << 8) | b;
        if (uns)
            d = d | (u32)0x10000000;
        return d;
        }

    static bool isDigit(u8 c)
        {
        return c >= (u8)'0' && c <= (u8)'9';
        }

    static u32 packDefaultKind(u32 w, u32 e, u32 m)
        {
        if (w == 8 && e == 4 && m == 3)
            return 1;
        return 0;
        }

    static String* packKindWord(u32 k)
        {
        if (k == 1)
            return String.withCString("finite");
        if (k == 2)
            return String.withCString("none");
        return String.withCString("ieee");
        }

    static String* packCanonical(u32 w, u32 e, u32 m, u32 kind, bool uns)
        {
        if (uns)
            return String.withCString("f8$ue8m0");
        if (w == 16 && e == 5 && m == 10 && kind == 0)
            return String.withCString("f16");
        if (w == 16 && e == 8 && m == 7 && kind == 0)
            return String.withCString("bf16");
        if (w == 8 && e == 4 && m == 3 && kind == 1)
            return String.withCString("f8");
        String* r = String.withCString("f");
        r.append(String.withU32(w));
        r.appendCString("$e");
        r.append(String.withU32(e));
        r.appendCString("m");
        r.append(String.withU32(m));
        if (kind != Types.packDefaultKind(w, e, m))
            {
            r.appendCString("$");
            r.append(Types.packKindWord(kind));
            }
        return r;
        }

    // A small float's canonical type name as the source writes it: `f8$e5m2`
    // is `f8:pack(e5m2)`, `f8$e4m3$ieee` is `f8:pack(e4m3, ieee)`. Every
    // diagnostic's text passes through here (Frontend.printDiagnostic). As
    // the reference's XTPackSpelling.
    static String* packSpelling(String* text)
        {
        if (text == 0 || text.byteIndexOf(String.withCString("$")) == String.notFound())
            return text;
        u32 n = text.byteLength();
        String* out = String.withCString("");
        u32 i = 0;
        while (i < n)
            {
            u32 head = 0;
            if (i + 3 <= n && text.byteAt(i) == (u8)'f' && text.byteAt(i + 1) == (u8)'8' && text.byteAt(i + 2) == (u8)'$')
                head = 3;
            else if (i + 4 <= n && text.byteAt(i) == (u8)'f' && text.byteAt(i + 1) == (u8)'1' && text.byteAt(i + 2) == (u8)'6'
                     && text.byteAt(i + 3) == (u8)'$')
                head = 4;
            if (head != 0 && (i == 0 || !Types.isIdentByte(text.byteAt(i - 1))))
                {
                u32 j = i + head;
                u32 split = j;
                if (j < n && text.byteAt(j) == (u8)'u')
                    j++;
                bool ok = j < n && text.byteAt(j) == (u8)'e';
                if (ok)
                    {
                    j++;
                    u32 d = j;
                    while (j < n && Types.isDigit(text.byteAt(j)))
                        j++;
                    ok = j > d && j < n && text.byteAt(j) == (u8)'m';
                    }
                if (ok)
                    {
                    j++;
                    u32 d2 = j;
                    while (j < n && Types.isDigit(text.byteAt(j)))
                        j++;
                    ok = j > d2;
                    }
                if (ok)
                    {
                    String* sp = text.substringBytes(split, j - split);
                    String* kind = (String*)0;
                    if (j < n && text.byteAt(j) == (u8)'$')
                        {
                        u32 k = j + 1;
                        while (k < n && text.byteAt(k) >= (u8)'a' && text.byteAt(k) <= (u8)'z')
                            k++;
                        if (k > j + 1)
                            {
                            kind = text.substringBytes(j + 1, k - j - 1);
                            j = k;
                            }
                        }
                    out.append(text.substringBytes(i, head - 1));
                    out.appendCString(":pack(");
                    out.append(sp);
                    if (kind != (String*)0)
                        {
                        out.appendCString(", ");
                        out.append(kind);
                        }
                    out.appendCString(")");
                    i = j;
                    continue;
                    }
                }
            out.appendByte(text.byteAt(i));
            i++;
            }
        return out;
        }

    static bool isIdentByte(u8 c)
        {
        return (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'0' && c <= (u8)'9')
            || c == (u8)'_';
        }

    // The message packNameFor gives when it refuses a pack.
    static String* _packErr;
    static String* packError(void)
        {
        return _packErr;
        }

    // The canonical name of `base:pack(pk)` or `base:pack(pk, kind)` (kind 0
    // when not written), as the parser fuses it; 0 when refused, with the
    // message in packError(). XTType packNameForBase:pack:kind:error:.
    static String* packNameFor(String* base, String* pk, String* kind)
        {
        _packErr = (String*)0;
        u32 sd = Types.packSplit(pk);
        u32 e = (sd >> 8) & (u32)0xFF;
        u32 m = sd & (u32)0xFF;
        bool uns = (sd & (u32)0x10000000) != 0;
        if (Types._is(base, "f32") || Types._is(base, "f64"))
            {
            String* own = Types._is(base, "f32") ? String.withCString("e8m23") : String.withCString("e11m52");
            if (!pk.equals(own))
                {
                String* er = String.withString(base);
                er.appendCString(" has no pack '");
                er.append(pk);
                er.appendCString("': it takes only its own, ");
                er.append(own);
                er.appendCString("; write '");
                er.append(base);
                er.appendCString("'");
                _packErr = er;
                return (String*)0;
                }
            if (kind != (String*)0)
                {
                String* er = String.withString(base);
                er.appendCString(" takes no special-value kind: its pack is IEEE's; write '");
                er.append(base);
                er.appendCString("'");
                _packErr = er;
                return (String*)0;
                }
            return base;
            }
        if (Types._is(base, "bf16"))
            {
            String* er = String.withCString("bf16 is already f16:pack(e8m7) and takes no pack; write 'bf16', or 'f16:pack(");
            er.append(pk);
            er.appendCString(")' for another layout of f16");
            _packErr = er;
            return (String*)0;
            }
        if (Types._is(base, "f4"))
            {
            _packErr = String.withCString("'f4' is not a type yet: the float types are f8, f16, bf16, f32 and f64");
            return (String*)0;
            }
        if (!Types._is(base, "f16") && !Types._is(base, "f8"))
            {
            String* er = String.withCString("'");
            er.append(base);
            er.appendCString("' has no pack: a pack is written on a float type, f8, f16, f32 or f64");
            _packErr = er;
            return (String*)0;
            }
        u32 w = Types._is(base, "f8") ? 8 : 16;
        if (w == 16 && (sd == 0 || uns || e + m + 1 != 16 || e < 5 || e > 8))
            {
            String* er = String.withCString("f16 has no pack '");
            er.append(pk);
            er.appendCString("': its packs are e5m10 (the default, IEEE binary16), e6m9, e7m8 and e8m7 (bfloat16)");
            _packErr = er;
            return (String*)0;
            }
        if (w == 8 && uns && !(sd != 0 && e == 8 && m == 0))
            {
            String* er = String.withCString("f8 has no pack '");
            er.append(pk);
            er.appendCString("': its one unsigned pack is ue8m0");
            _packErr = er;
            return (String*)0;
            }
        if (w == 8 && !uns && (sd == 0 || e + m + 1 != 8 || e < 2 || m < 1))
            {
            String* er = String.withCString("f8 has no pack '");
            er.append(pk);
            er.appendCString("': a signed pack has 1 + X + Y = 8 bits, e2m5 to e6m1 (e4m3 the default, e5m2), and the unsigned scale is ue8m0");
            _packErr = er;
            return (String*)0;
            }
        if (uns)
            {
            if (kind != (String*)0)
                {
                _packErr = String.withCString("ue8m0 takes no special-value kind: 0xFF is its NaN and it has no infinity; write 'f8:pack(ue8m0)'");
                return (String*)0;
                }
            return Types.packCanonical(8, 8, 0, 1, true);
            }
        u32 k = Types.packDefaultKind(w, e, m);
        if (kind != (String*)0)
            {
            if (Types._is(kind, "ieee"))
                k = 0;
            else if (Types._is(kind, "finite"))
                k = 1;
            else if (Types._is(kind, "none"))
                k = 2;
            else
                {
                String* er = String.withCString("'");
                er.append(kind);
                er.appendCString("' is not a special-value kind: write ieee, finite or none");
                _packErr = er;
                return (String*)0;
                }
            }
        if (k != 0 && e > 7)
            {
            String* er = String.withCString("a ");
            er.append(Types.packKindWord(k));
            er.appendCString(" pack has at most 7 exponent bits, so that its largest values fit f32; write 'f");
            er.append(String.withU32(w));
            er.appendCString(":pack(");
            er.append(pk);
            er.appendCString(")'");
            _packErr = er;
            return (String*)0;
            }
        return Types.packCanonical(w, e, m, k, false);
        }

    static bool isPack(String* t)
        {
        return Types.packDesc(t) != 0;
        }

    // The pack's exponent and mantissa widths, kind, signedness and width.
    static u32 packExp(String* t)
        {
        return (Types.packDesc(t) >> 8) & (u32)0xFF;
        }
    static u32 packMant(String* t)
        {
        return Types.packDesc(t) & (u32)0xFF;
        }
    static u32 packKind(String* t)
        {
        return (Types.packDesc(t) >> 24) & (u32)3;
        }
    static bool packUnsigned(String* t)
        {
        return (Types.packDesc(t) & (u32)0x10000000) != 0;
        }
    static u32 packWidth(String* t)
        {
        return (Types.packDesc(t) >> 16) & (u32)0xFF;
        }
    // The routines' pack word beyond (e, m): the kind, 4 for unsigned; 0 for
    // an ieee signed pack, which FloatPack.xc's routines take as (e, m).
    static u32 packFlags(String* t)
        {
        u32 d = Types.packDesc(t);
        if (d == 0)
            return 0;
        u32 f = (d >> 24) & (u32)3;
        if ((d & (u32)0x10000000) != 0)
            f = f | (u32)4;
        return f;
        }
    // The two packs C has: f16 and bf16.
    static bool isCPack(String* t)
        {
        return Types._is(t, "f16") || Types._is(t, "bf16");
        }
    static u32 packSignBit(String* t)
        {
        u32 d = Types.packDesc(t);
        if (d == 0 || (d & (u32)0x10000000) != 0)
            return 0;
        u32 one = 1;
        return one << (((d >> 8) & (u32)0xFF) + (d & (u32)0xFF));
        }

    // 2^n, exactly.
    static f64 pow2(i32 n)
        {
        f64 r = 1.0;
        while (n > 0)
            {
            r = r * 2.0;
            n = n - 1;
            }
        while (n < 0)
            {
            r = r * 0.5;
            n = n + 1;
            }
        return r;
        }

    static u32 packMaxBits(u32 e, u32 m, u32 kind, bool uns)
        {
        u32 one = 1;
        if (uns)
            return (u32)0xFE;
        u32 all = (one << (e + m)) - one;
        if (kind == 0)
            return (((one << e) - one) << m) - one;
        if (kind == 1)
            return all - one;
        return all;
        }

    // The value of a finite pattern (magnitude bits) of a pack.
    static f64 packValue(u32 bits, u32 e, u32 m, bool uns)
        {
        u32 one = 1;
        if (uns)
            return Types.pow2((i32)bits - 127);
        u32 ex = bits >> m;
        u32 mant = bits & ((one << m) - one);
        i32 bias = (i32)((one << (e - one)) - one);
        if (ex == 0)
            return (f64)mant * Types.pow2(1 - bias - (i32)m);
        return (f64)((one << m) | mant) * Types.pow2((i32)ex - bias - (i32)m);
        }

    static f64 packMaxFinite(String* t)
        {
        u32 d = Types.packDesc(t);
        if (d == 0)
            return 0.0;
        u32 e = (d >> 8) & (u32)0xFF;
        u32 m = d & (u32)0xFF;
        bool uns = (d & (u32)0x10000000) != 0;
        return Types.packValue(Types.packMaxBits(e, m, (d >> 24) & (u32)3, uns), e, m, uns);
        }

    // It as a diagnostic writes it: an integer below 1e10 in full, any other
    // value below that exactly, a larger one to three figures (3.39e38).
    // XTType.packMaxFiniteText.
    static String* packMaxText(String* t)
        {
        f64 v = Types.packMaxFinite(t);
        if (v < 1e10)
            {
            i64 ip = (i64)v;
            f64 frac = v - (f64)ip;
            String* s = String.withI64(ip);
            if (frac > 0.0)
                {
                s.appendCString(".");
                while (frac > 0.0)
                    {
                    frac = frac * 10.0;
                    i64 dg = (i64)frac;
                    s.append(String.withI64(dg));
                    frac = frac - (f64)dg;
                    }
                }
            return s;
            }
        f64 dd = v;
        i64 n = 0;
        while (dd >= 10.0)
            {
            dd = dd / 10.0;
            n = n + 1;
            }
        i64 r = (i64)(dd * 100.0 + 0.5);
        if (r >= 1000)
            {
            r = r / 10;
            n = n + 1;
            }
        String* s = String.withI64(r / 100);
        s.appendCString(".");
        s.append(String.withI64(r / 10 % 10));
        s.append(String.withI64(r % 10));
        s.appendCString("e");
        s.append(String.withI64(n));
        return s;
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

    // A value as its sign, the unbiased exponent of bit 31 of sig, and sig,
    // rounded to a pack: FloatPackKinds.xc's _xt_fpk_roundk (FloatPack.xc's
    // _xt_fpk_round for k 0), the same steps. Bit 31 of the result says the
    // rounded magnitude was beyond the largest finite value.
    static u32 packRound(u32 sign, i32 unb, u32 sig, u32 e, u32 m, u32 k)
        {
        u32 one = 1;
        u32 kind = k & (u32)3;
        if ((k & (u32)4) != 0)
            {
            if (sign != 0)
                return (u32)0xFF;
            while ((sig & (u32)0x80000000) == 0)
                {
                sig = sig << 1;
                unb = unb - 1;
                }
            i32 ue = unb + 127;
            u32 urem = sig & (u32)0x7FFFFFFF;
            if (urem > (u32)0x40000000 || (urem == (u32)0x40000000 && (ue & 1) != 0))
                ue = ue + 1;
            if (ue < 0)
                return 0;
            if (ue > 254)
                {
                if ((k & (u32)8) != 0)
                    return (u32)0x800000FF;
                return (u32)0x800000FE;
                }
            return (u32)ue;
            }
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
        u32 all = (one << (e + m)) - one;
        u32 inf = ((one << e) - one) << m;
        u32 over = 0;
        if (kind == 0 && bits >= inf)
            {
            over = (u32)0x80000000;
            bits = inf;
            if ((k & (u32)16) != 0)
                bits = inf - one;
            }
        else if (kind == 1 && bits >= all)
            {
            over = (u32)0x80000000;
            bits = all - one;
            if ((k & (u32)8) != 0)
                bits = all;
            }
        else if (kind == 2 && bits > all)
            {
            over = (u32)0x80000000;
            bits = all;
            }
        return over | (sign << (e + m)) | bits;
        }

    // A double, given as its bits, rounded to a pack: FloatPack.xc's
    // _xt_fpk_pack_f64 and FloatPackKinds.xc's _xt_fpk_pack_f64k, the same
    // steps; bit 31 as packRound. XTPackRoundDouble.
    static u32 packRoundDouble(u64 x, u32 e, u32 m, u32 k)
        {
        u32 one = 1;
        u32 kind = k & (u32)3;
        bool uns = (k & (u32)4) != 0;
        u32 hi = (u32)(x >> 32);
        u32 lo = (u32)x;
        u32 sign = hi >> 31;
        u32 ex = (hi >> 20) & (u32)0x7FF;
        u32 mhi = hi & (u32)0xFFFFF;
        u32 sig = (mhi << 11) | (lo >> 21);
        if ((lo & (u32)0x1FFFFF) != 0)
            sig = sig | one;
        u32 all = (one << (e + m)) - one;
        u32 sbit = sign << (e + m);
        if (uns)
            {
            all = (u32)0xFF;
            sbit = 0;
            }
        if (ex == (u32)0x7FF)
            {
            if (mhi == 0 && lo == 0)
                {
                if (uns)
                    {
                    if (sign != 0 || (k & (u32)8) != 0)
                        return (u32)0xFF;
                    return (u32)0xFE;
                    }
                if (kind == 0)
                    {
                    if ((k & (u32)16) != 0)
                        return sbit | Types.packMaxBits(e, m, 0, false);
                    return sbit | (((one << e) - one) << m);
                    }
                if (kind == 1 && (k & (u32)8) != 0)
                    return sbit | all;
                return sbit | Types.packMaxBits(e, m, kind, false);
                }
            if (uns)
                return (u32)0xFF;
            if (kind == 1)
                return sbit | all;
            if (kind == 2)
                return 0;
            u32 top = (sig << 1) | one;
            return sbit | (((one << e) - one) << m) | (one << (m - one)) | (top >> (32 - m));
            }
        if (ex == 0 && mhi == 0 && lo == 0)
            {
            if (uns)
                return 0;
            return sbit;
            }
        i32 unb = ex == 0 ? -1022 : (i32)ex - 1023;
        if (ex != 0)
            sig = sig | (u32)0x80000000;
        return Types.packRound(sign, unb, sig, e, m, k);
        }

    // A double, given as its bits, rounded to the pack `t`, as its pattern.
    // XTType.packBitsForDouble:.
    static u32 packBits(u64 x, String* t)
        {
        return Types.packRoundDouble(x, Types.packExp(t), Types.packMant(t), Types.packFlags(t)) & (u32)0xFFFF;
        }

    // Is a literal (its double's bits) beyond the pack: rounds past its
    // largest finite value, or (unsigned) is zero or negative?
    // XTType.packLiteralOutOfRange:.
    static bool packLiteralOutOfRange(u64 x, String* t)
        {
        if (Types.packUnsigned(t) && Types.literalNotPositive(x))
            return true;
        return (Types.packRoundDouble(x, Types.packExp(t), Types.packMant(t), Types.packFlags(t)) & (u32)0x80000000) != 0;
        }

    // A double's bits: zero, negative or NaN.
    static bool literalNotPositive(u64 x)
        {
        u64 mag = x & (u64)0x7FFFFFFFFFFFFFFF;
        if (mag == 0 || mag > (u64)0x7FF0000000000000)
            return true;
        return (x >> 63) != 0;
        }

    // The numbers packHolds compares, for a pack, f32 or f64 (XTPackShape).
    static bool packShapeKnown(String* t)
        {
        return Types.isPack(t) || Types.isFloating(t);
        }
    static u32 packShapeMant(String* t)
        {
        if (Types._is(t, "double"))
            return 52;
        if (Types._is(t, "float"))
            return 23;
        return Types.packMant(t);
        }
    static i32 packShapeQmin(String* t)
        {
        u32 one = 1;
        if (Types._is(t, "double"))
            return -1074;
        if (Types._is(t, "float"))
            return -149;
        if (Types.packUnsigned(t))
            return -127;
        i32 bias = (i32)((one << (Types.packExp(t) - one)) - one);
        return 1 - bias - (i32)Types.packMant(t);
        }
    static f64 packShapeMax(String* t)
        {
        if (Types._is(t, "double"))
            return (2.0 - Types.pow2(-52)) * Types.pow2(1023);
        if (Types._is(t, "float"))
            return (2.0 - Types.pow2(-23)) * Types.pow2(127);
        return Types.packMaxFinite(t);
        }
    static bool packShapeInf(String* t)
        {
        if (Types.isFloating(t))
            return true;
        return Types.packKind(t) == 0 && !Types.packUnsigned(t);
        }
    static bool packShapeNan(String* t)
        {
        if (Types.isFloating(t))
            return true;
        return Types.packKind(t) != 2;
        }

    // Does every value of `from` (a pack, f32 or f64) convert exactly to `to`
    // (the same), its infinities and NaNs included? XTType packHolds:in:.
    static bool packHolds(String* from, String* to)
        {
        if (from == 0 || to == 0)
            return false;
        if (from.equals(to))
            return true;
        if (!Types.packShapeKnown(from) || !Types.packShapeKnown(to))
            return false;
        bool ua = Types.packUnsigned(from);
        bool ub = Types.packUnsigned(to);
        if (ub && !ua)
            return false;
        if (Types.packShapeInf(from) && !Types.packShapeInf(to))
            return false;
        if (Types.packShapeNan(from) && !Types.packShapeNan(to))
            return false;
        return Types.packShapeMant(to) >= Types.packShapeMant(from) && Types.packShapeQmin(from) >= Types.packShapeQmin(to)
            && Types.packShapeMax(from) <= Types.packShapeMax(to);
        }

    // Can a value of `from` reach a slot of `to` with no cast? Only when every
    // value converts exactly (packHolds). An integer, f32 or f64 reaches a
    // pack through a cast. XTType.packConvertsImplicitly:to:.
    static bool packConvertsImplicitly(String* from, String* to)
        {
        if (from == 0 || to == 0)
            return true;
        if (Types.isPack(to))
            return Types.isPack(from) && Types.packHolds(from, to);
        if (Types.isPack(from))
            return Types.isFloating(to) && Types.packHolds(from, to);
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
            return Types.packWidth(t) / 8;
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
        // A small float widens to the type that holds both operands: the pack
        // that holds the other, itself for an integer it holds every value of
        // (f16 and bf16 an 8-bit one), f32 for a wider one up to 16 bits, f64
        // beyond; two packs neither of which holds the other have no common
        // type (sema refuses them). XTType.widenType:with:.
        if (Types.isPack(a) || Types.isPack(b))
            {
            String* p = Types.isPack(a) ? a : b;
            String* o = Types.isPack(a) ? b : a;
            if (Types._is(o, "double"))
                return String.withCString("double");
            if (Types._is(o, "float"))
                return String.withCString("float");
            if (Types.isPack(o))
                {
                if (o.equals(p) || Types.packHolds(o, p))
                    return p;
                if (Types.packHolds(p, o))
                    return o;
                return String.withCString("float");
                }
            if (Types._is(o, "u8") || Types._is(o, "i8") || Types._is(o, "bool") || Types.isEnumName(o))
                {
                if (!Types.packUnsigned(p) && Types.packMant(p) >= 7 && Types.packMaxFinite(p) >= 256.0)
                    return p;
                return String.withCString("float");
                }
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
