// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.
// Predicate.xc — conditions over records, built in code or parsed from text
// (NSPredicate in shape).
// ===========================================================================
//
//     Predicate* p = Predicate.parse(String.withCString("age > 30 AND name CONTAINS[c] 'sm'"));
//     Map* person = (Map*)JSON.parse(String.withCString("{\"name\":\"Smith\",\"age\":42}"));
//     p.evaluate(person);     // true
//
// A predicate is a tree: comparisons (key OP value) joined by AND, OR and
// NOT. The thing tested is a Map, such as a JSON object or a CSV record, or
// any object through a callback that reads a key:
//
//     bool ok = p.evaluateWith(&row.valueForKey);   // Object* valueForKey(String* key)
//
// A key may be a path: "address.city" reads "address" and then "city" in the
// Map found there.
//
// ── Comparing ───────────────────────────────────────────────────────────────
//
// Two Numbers compare as numbers. A Number and a String that holds a number
// also compare as numbers, so records read from text work; the String must
// be written as JSON writes a number ("42", "-1.5e3"), so "02139" stays text. Two Strings
// compare by bytes (or ignoring ASCII case with [c]). Otherwise only = and
// != apply, by `equals`. A missing key reads as null, which equals only null
// and is neither less nor more than anything.
//
//     =  ==  !=  <>  <  >  <=  >=
//     CONTAINS  BEGINSWITH  ENDSWITH     substring tests on Strings
//     LIKE                               wildcards: * any run, ? one character
//     MATCHES                            a Regex that must match the whole value
//     IN { 'a', 'b', 3 }                 the value is one of these
//
// Any of them may take [c] for case-insensitive (ASCII). In text, keywords
// are in any case, strings are in single or double quotes with \ escapes,
// numbers are integers or decimals, and TRUE, FALSE and NULL are values.
// TRUEPREDICATE and FALSEPREDICATE are the constant predicates.
//
// ── Errors ──────────────────────────────────────────────────────────────────
//
// parse throws a PredicateError, with the byte offset, for text it cannot
// read, and for a MATCHES pattern that is not a valid Regex.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every target except xt6502.

#if ARCH_6502
#error "Predicate: not available on xt6502"
#endif

#import "Foundation.xc"
#import "Error.xc"
#import "JSON.xc"
#import "Regex.xc"

class PredicateError <Error>
    {
    String* _message;

    void init(String* message)
        {
        _message = message;
        }

    String* message(void)
        {
        return _message;
        }
    }

enum _PredKind = {PK_TRUE, PK_FALSE, PK_AND, PK_OR, PK_NOT, PK_COMPARE};
enum _PredOp = {PO_EQ, PO_NE, PO_LT, PO_GT, PO_LE, PO_GE, PO_CONTAINS, PO_BEGINS, PO_ENDS, PO_LIKE, PO_MATCHES, PO_IN};

class Predicate : Object
    {
    u8 _kind;
    Array* _subs;    // AND, OR: two or more; NOT: one
    String* _key;
    u8 _op;
    Object* _value;  // a String, Number, Null, or an Array for IN
    bool _fold;      // [c]
    Regex* _regex;   // MATCHES

    // ── Building ─────────────────────────────────────────────────────────

    static Predicate* _make(u8 kind)
        {
        Predicate* p = new Predicate();
        p._kind = kind;
        p._subs = new Array();
        return p;
        }

    static Predicate* truePredicate(void)
        {
        return Predicate._make((u8)PK_TRUE);
        }

    static Predicate* falsePredicate(void)
        {
        return Predicate._make((u8)PK_FALSE);
        }

    static Predicate* and(Predicate* a, Predicate* b)
        {
        Predicate* p = Predicate._make((u8)PK_AND);
        p._subs.add(a);
        p._subs.add(b);
        return p;
        }

    static Predicate* or(Predicate* a, Predicate* b)
        {
        Predicate* p = Predicate._make((u8)PK_OR);
        p._subs.add(a);
        p._subs.add(b);
        return p;
        }

    static Predicate* not(Predicate* a)
        {
        Predicate* p = Predicate._make((u8)PK_NOT);
        p._subs.add(a);
        return p;
        }

    // AND or OR of every predicate in `parts` (an empty AND is true, an empty
    // OR false).
    static Predicate* andAll(Array* parts)
        {
        Predicate* p = Predicate._make((u8)PK_AND);
        p._subs.addAll(parts);
        return p;
        }

    static Predicate* orAll(Array* parts)
        {
        Predicate* p = Predicate._make((u8)PK_OR);
        p._subs.addAll(parts);
        return p;
        }

    // `key` compared to `value` by `op`, one of the comparison names: "=",
    // "!=", "<", ">", "<=", ">=", "CONTAINS", "BEGINSWITH", "ENDSWITH",
    // "LIKE", "MATCHES", "IN" (with an Array value). `caseInsensitive` is
    // [c]. Throws for an unknown operator or a bad MATCHES pattern.
    static Predicate* compare(String* key, String* op, Object* value, bool caseInsensitive) throws
        {
        i32 code = Predicate._opCode(op);
        if (code < (i32)0)
            {
            String* m = String.withCString("Predicate: unknown operator ");
            m.append(op);
            throw new PredicateError(m);
            }
        return Predicate._comparison(key, (u8)code, value, caseInsensitive);
        }

    static Predicate* _comparison(String* key, u8 op, Object* value, bool fold) throws
        {
        Predicate* p = Predicate._make((u8)PK_COMPARE);
        p._key = key;
        p._op = op;
        p._value = value == 0 ? (Object*)Null.null() : value;
        p._fold = fold;
        if (op == (u8)PO_MATCHES)
            {
            String* pat = (String* ?)value;
            if (pat == 0)
                throw new PredicateError(String.withCString("Predicate: MATCHES needs a String pattern"));
            try
                {
                p._regex = Regex.compileWith(pat, fold ? Regex.caseInsensitive() : (u8)0);
                }
            catch (RegexError e)
                {
                throw new PredicateError(e.message());
                }
            }
        return p;
        }

    static i32 _opCode(String* op)
        {
        if (op == 0)
            return (i32)-1;
        String* u = op.uppercased();
        if (u.equals(String.withCString("=")) || u.equals(String.withCString("==")))
            return (i32)PO_EQ;
        if (u.equals(String.withCString("!=")) || u.equals(String.withCString("<>")))
            return (i32)PO_NE;
        if (u.equals(String.withCString("<")))
            return (i32)PO_LT;
        if (u.equals(String.withCString(">")))
            return (i32)PO_GT;
        if (u.equals(String.withCString("<=")))
            return (i32)PO_LE;
        if (u.equals(String.withCString(">=")))
            return (i32)PO_GE;
        if (u.equals(String.withCString("CONTAINS")))
            return (i32)PO_CONTAINS;
        if (u.equals(String.withCString("BEGINSWITH")))
            return (i32)PO_BEGINS;
        if (u.equals(String.withCString("ENDSWITH")))
            return (i32)PO_ENDS;
        if (u.equals(String.withCString("LIKE")))
            return (i32)PO_LIKE;
        if (u.equals(String.withCString("MATCHES")))
            return (i32)PO_MATCHES;
        if (u.equals(String.withCString("IN")))
            return (i32)PO_IN;
        return (i32)-1;
        }

    // ── Evaluating ───────────────────────────────────────────────────────

    // Tests `record`, a Map (keys and paths read through nested Maps). Any
    // other object has no keys: every key reads as null.
    bool evaluate(Object* record)
        {
        return _eval(record);
        }

    // Tests an object through `read`, which returns the value of a key (a
    // String, Number or Null; null for none).
    bool evaluateWith(callback read Object*(String* key))
        {
        return _evalWith(read);
        }

    // The members of `items` (Maps) that pass, in order.
    Array* filter(Array* items)
        {
        Array* out = new Array();
        if (items == 0)
            return out;
        for (u32 i = (u32)0; i < items.count(); i++)
            {
            if (evaluate(items.get(i)))
                out.add(items.get(i));
            }
        return out;
        }

    bool _evalWith(callback read Object*(String* key))
        {
        if (_kind == (u8)PK_TRUE)
            return true;
        if (_kind == (u8)PK_FALSE)
            return false;
        if (_kind == (u8)PK_NOT)
            return !((Predicate*)_subs.get((u32)0))._evalWith(read);
        if (_kind == (u8)PK_AND)
            {
            for (u32 i = (u32)0; i < _subs.count(); i++)
                {
                if (!((Predicate*)_subs.get(i))._evalWith(read))
                    return false;
                }
            return true;
            }
        if (_kind == (u8)PK_OR)
            {
            for (u32 i = (u32)0; i < _subs.count(); i++)
                {
                if (((Predicate*)_subs.get(i))._evalWith(read))
                    return true;
                }
            return false;
            }
        Object* v = (Object*)0;
        if (read)
            v = read(_key);
        return _test(v);
        }

    bool _eval(Object* record)
        {
        if (_kind == (u8)PK_TRUE)
            return true;
        if (_kind == (u8)PK_FALSE)
            return false;
        if (_kind == (u8)PK_NOT)
            return !((Predicate*)_subs.get((u32)0))._eval(record);
        if (_kind == (u8)PK_AND)
            {
            for (u32 i = (u32)0; i < _subs.count(); i++)
                {
                if (!((Predicate*)_subs.get(i))._eval(record))
                    return false;
                }
            return true;
            }
        if (_kind == (u8)PK_OR)
            {
            for (u32 i = (u32)0; i < _subs.count(); i++)
                {
                if (((Predicate*)_subs.get(i))._eval(record))
                    return true;
                }
            return false;
            }
        return _test(Predicate.valueAtPath(record, _key));
        }

    // The value at a dotted key path through nested Maps, or null.
    static Object* valueAtPath(Object* record, String* path)
        {
        if (path == 0)
            return (Object*)0;
        Object* at = record;
        u8* p = path.cString();
        u32 n = path.byteLength();
        u32 start = (u32)0;
        for (u32 i = (u32)0; i <= n; i++)
            {
            if (i == n || p[i] == (u8)'.')
                {
                Map* m = (Map* ?)at;
                if (m == 0)
                    return (Object*)0;
                at = m.get(path.substringBytes(start, i - start));
                start = i + (u32)1;
                }
            }
        return at;
        }

    // A Number for a String that holds a number, else null.
    static Number* _asNumber(Object* v)
        {
        Number* n = (Number* ?)v;
        if (n != 0)
            return n;
        String* s = (String* ?)v;
        if (s == 0 || s.byteLength() == (u32)0)
            return (Number*)0;
        try
            {
            return (Number* ?)JSON.parse(s.trimmed());
            }
        catch (JSONError e)
            {
            }
        return (Number*)0;
        }

    // <0, 0, >0, or 2 when the two have no order.
    i32 _order(Object* a, Object* b)
        {
        if (a == 0 || b == 0 || Null.isNull(a) || Null.isNull(b))
            return (i32)2;
        String* sa = (String* ?)a;
        String* sb = (String* ?)b;
        Number* na = (Number* ?)a;
        Number* nb = (Number* ?)b;
        if (na != 0 || nb != 0)
            {
            Number* x = na != 0 ? na : Predicate._asNumber(a);
            Number* y = nb != 0 ? nb : Predicate._asNumber(b);
            if (x == 0 || y == 0)
                return (i32)2;
            if (x.isFloat() || y.isFloat())
                {
                double p = x.asDouble();
                double q = y.asDouble();
                return p < q ? (i32)-1 : (p > q ? (i32)1 : (p == q ? (i32)0 : (i32)2));
                }
            i64 p = x.asI64();
            i64 q = y.asI64();
            return p < q ? (i32)-1 : (p > q ? (i32)1 : (i32)0);
            }
        if (sa != 0 && sb != 0)
            {
            if (_fold)
                return (i32)sa.lowercased().compare(sb.lowercased());
            return (i32)sa.compare(sb);
            }
        return (i32)2;
        }

    bool _same(Object* a, Object* b)
        {
        bool an = a == 0 || Null.isNull(a);
        bool bn = b == 0 || Null.isNull(b);
        if (an || bn)
            return an && bn;
        i32 o = _order(a, b);
        if (o != (i32)2)
            return o == (i32)0;
        return a.equals(b);
        }

    bool _test(Object* v)
        {
        u8 op = _op;
        if (op == (u8)PO_EQ)
            return _same(v, _value);
        if (op == (u8)PO_NE)
            return !_same(v, _value);
        if (op <= (u8)PO_GE)
            {
            i32 o = _order(v, _value);
            if (o == (i32)2)
                return false;
            if (op == (u8)PO_LT)
                return o < (i32)0;
            if (op == (u8)PO_GT)
                return o > (i32)0;
            if (op == (u8)PO_LE)
                return o <= (i32)0;
            return o >= (i32)0;
            }
        if (op == (u8)PO_IN)
            {
            Array* list = (Array* ?)_value;
            if (list == 0)
                return false;
            for (u32 i = (u32)0; i < list.count(); i++)
                {
                if (_same(v, list.get(i)))
                    return true;
                }
            return false;
            }
        // The rest are tests on text; a Number is tested as its description.
        String* s = (String* ?)v;
        if (s == 0)
            {
            Number* n = (Number* ?)v;
            if (n == 0)
                return false;
            s = n.description();
            }
        if (op == (u8)PO_MATCHES)
            return _regex.matches(s);
        String* t = (String* ?)_value;
        if (t == 0)
            return false;
        if (_fold)
            {
            s = s.lowercased();
            t = t.lowercased();
            }
        if (op == (u8)PO_CONTAINS)
            return t.byteLength() == (u32)0 || s.contains(t);
        if (op == (u8)PO_BEGINS)
            return s.hasPrefix(t);
        if (op == (u8)PO_ENDS)
            return s.hasSuffix(t);
        return Predicate._like(s.cString(), s.byteLength(), t.cString(), t.byteLength());
        }

    // Wildcard match: * any run, ? one byte (a whole UTF-8 character).
    static bool _like(u8* s, u32 n, u8* p, u32 m)
        {
        u32 i = (u32)0;
        u32 j = (u32)0;
        u32 starP = (u32)0xFFFFFFFF;
        u32 starS = (u32)0;
        while (i < n)
            {
            if (j < m && p[j] == (u8)'*')
                {
                starP = j;
                starS = i;
                j++;
                }
            else if (j < m && (p[j] == (u8)'?' || p[j] == s[i]))
                {
                if (p[j] == (u8)'?')
                    {
                    // One character, all of it.
                    i32 len;
                    Regex._decode(s, (i32)i, (i32)n, &len);
                    i = i + (u32)len;
                    }
                else
                    i++;
                j++;
                }
            else if (starP != (u32)0xFFFFFFFF)
                {
                j = starP + (u32)1;
                starS++;
                i = starS;
                }
            else
                return false;
            }
        while (j < m && p[j] == (u8)'*')
            j++;
        return j == m;
        }

    // ── Text ─────────────────────────────────────────────────────────────

    // The predicate in the format parse reads.
    String* description(void)
        {
        String* s = String.withCString("");
        _describe(s, false);
        return s;
        }

    void _describe(String* s, bool nested)
        {
        if (_kind == (u8)PK_TRUE)
            {
            s.appendCString("TRUEPREDICATE");
            return;
            }
        if (_kind == (u8)PK_FALSE)
            {
            s.appendCString("FALSEPREDICATE");
            return;
            }
        if (_kind == (u8)PK_NOT)
            {
            s.appendCString("NOT ");
            ((Predicate*)_subs.get((u32)0))._describe(s, true);
            return;
            }
        if (_kind == (u8)PK_AND || _kind == (u8)PK_OR)
            {
            if (_subs.count() == (u32)0)
                {
                s.appendCString(_kind == (u8)PK_AND ? "TRUEPREDICATE" : "FALSEPREDICATE");
                return;
                }
            if (nested)
                s.appendCString("(");
            for (u32 i = (u32)0; i < _subs.count(); i++)
                {
                if (i > (u32)0)
                    s.appendCString(_kind == (u8)PK_AND ? " AND " : " OR ");
                ((Predicate*)_subs.get(i))._describe(s, true);
                }
            if (nested)
                s.appendCString(")");
            return;
            }
        s.append(_key);
        u8* names = (u8*)"=\0!=\0<\0>\0<=\0>=\0CONTAINS\0BEGINSWITH\0ENDSWITH\0LIKE\0MATCHES\0IN\0";
        u32 at = (u32)0;
        for (u8 k = (u8)0; k < _op; k++)
            at = at + String._cstringLen(&names[at]) + (u32)1;
        s.appendCString(" ");
        s.appendCString(&names[at]);
        if (_fold)
            s.appendCString("[c]");
        s.appendCString(" ");
        Predicate._describeValue(s, _value);
        }

    static void _describeValue(String* s, Object* v)
        {
        if (v == 0 || Null.isNull(v))
            {
            s.appendCString("NULL");
            return;
            }
        Array* list = (Array* ?)v;
        if (list != 0)
            {
            s.appendCString("{");
            for (u32 i = (u32)0; i < list.count(); i++)
                {
                if (i > (u32)0)
                    s.appendCString(", ");
                Predicate._describeValue(s, list.get(i));
                }
            s.appendCString("}");
            return;
            }
        String* str = (String* ?)v;
        if (str != 0)
            {
            s.appendCString("'");
            u8* p = str.cString();
            for (u32 i = (u32)0; i < str.byteLength(); i++)
                {
                if (p[i] == (u8)'\'' || p[i] == (u8)'\\')
                    s.appendByte((u8)'\\');
                s.appendByte(p[i]);
                }
            s.appendCString("'");
            return;
            }
        Number* n = (Number* ?)v;
        if (n != 0 && n.isBool())
            {
            s.appendCString(n.asBool() ? "TRUE" : "FALSE");
            return;
            }
        if (n != 0 && n.isFloat())
            {
            _json_appendDouble(s, n.asDouble(), false);
            return;
            }
        s.append(v.description());
        }

    // ── Parsing ──────────────────────────────────────────────────────────

    // Reads the format described above.
    static Predicate* parse(String* text) throws
        {
        if (text == 0)
            throw new PredicateError(String.withCString("Predicate: no text"));
        _PredParser* r = new _PredParser();
        r.p = text.cString();
        r.n = text.byteLength();
        Predicate* p = r.or();
        r.ws();
        if (r.i < r.n)
            r.fail("unexpected text after the predicate");
        return p;
        }
    }

class _PredParser
    {
    u8* p;
    u32 n;
    u32 i;

    void fail(u8* why) throws
        {
        String* m = String.withCString("bad predicate at byte ");
        m.append(String.withU32(i));
        m.appendCString(": ");
        m.appendCString(why);
        throw new PredicateError(m);
        }

    void ws(void)
        {
        u8* q = p;
        while (i < n && (q[i] == (u8)' ' || q[i] == (u8)'\t' || q[i] == (u8)'\n' || q[i] == (u8)'\r'))
            i++;
        }

    static bool isName(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'0' && c <= (u8)'9')
               || c == (u8)'_' || c == (u8)'.' || c >= (u8)$80;
        }

    // The next word (a run of name characters), without consuming it.
    String* peekWord(void)
        {
        ws();
        u8* q = p;
        u32 k = i;
        while (k < n && _PredParser.isName(q[k]))
            k++;
        return String.withBytes(&q[i], k - i);
        }

    // Consumes the keyword `w` (any case) if it is next as a whole word.
    bool keyword(u8* w)
        {
        String* next = peekWord();
        if (next.byteLength() == (u32)0 || !next.uppercased().equals(String.withCString(w)))
            return false;
        i = i + next.byteLength();
        return true;
        }

    // Consumes the symbol `s` if it is next.
    bool symbol(u8* s)
        {
        ws();
        u8* q = p;
        u32 k = (u32)0;
        while (s[k] != (u8)0)
            {
            if (i + k >= n || q[i + k] != s[k])
                return false;
            k++;
            }
        i = i + k;
        return true;
        }

    Predicate* or(void) throws
        {
        Predicate* l = and();
        Array* parts = (Array*)0;
        while (keyword("OR") || symbol("||"))
            {
            if (parts == 0)
                {
                parts = new Array();
                parts.add(l);
                }
            parts.add(and());
            }
        return parts == 0 ? l : Predicate.orAll(parts);
        }

    Predicate* and(void) throws
        {
        Predicate* l = not();
        Array* parts = (Array*)0;
        while (keyword("AND") || symbol("&&"))
            {
            if (parts == 0)
                {
                parts = new Array();
                parts.add(l);
                }
            parts.add(not());
            }
        return parts == 0 ? l : Predicate.andAll(parts);
        }

    Predicate* not(void) throws
        {
        if (keyword("NOT"))
            return Predicate.not(not());
        ws();
        u8* q = p;
        if (i < n && q[i] == (u8)'!' && !(i + (u32)1 < n && q[i + (u32)1] == (u8)'='))
            {
            i++;
            return Predicate.not(not());
            }
        return primary();
        }

    Predicate* primary(void) throws
        {
        if (symbol("("))
            {
            Predicate* inner = or();
            if (!symbol(")"))
                fail("expected ')'");
            return inner;
            }
        if (keyword("TRUEPREDICATE"))
            return Predicate.truePredicate();
        if (keyword("FALSEPREDICATE"))
            return Predicate.falsePredicate();
        String* key = peekWord();
        if (key.byteLength() == (u32)0)
            fail("expected a key");
        u8 first = key.byteAt((u32)0);
        if (first >= (u8)'0' && first <= (u8)'9')
            fail("a key cannot start with a digit");
        i = i + key.byteLength();
        u32 opAt = i;
        i32 op = (i32)-1;
        if (symbol("=="))
            op = (i32)PO_EQ;
        else if (symbol("!="))
            op = (i32)PO_NE;
        else if (symbol("<>"))
            op = (i32)PO_NE;
        else if (symbol("<="))
            op = (i32)PO_LE;
        else if (symbol(">="))
            op = (i32)PO_GE;
        else if (symbol("="))
            op = (i32)PO_EQ;
        else if (symbol("<"))
            op = (i32)PO_LT;
        else if (symbol(">"))
            op = (i32)PO_GT;
        else
            {
            String* w = peekWord();
            i32 code = Predicate._opCode(w);
            if (code >= (i32)PO_CONTAINS)
                {
                op = code;
                i = i + w.byteLength();
                }
            }
        if (op < (i32)0)
            {
            i = opAt;
            fail("expected an operator");
            }
        bool fold = false;
        if (symbol("[c]") || symbol("[C]"))
            fold = true;
        Object* value;
        if (op == (i32)PO_IN)
            {
            if (!symbol("{"))
                fail("IN needs a { list }");
            Array* list = new Array();
            if (!symbol("}"))
                {
                list.add(readValue());
                while (symbol(","))
                    list.add(readValue());
                if (!symbol("}"))
                    fail("expected ',' or '}'");
                }
            value = (Object*)list;
            }
        else
            value = readValue();
        try
            {
            return Predicate._comparison(key, (u8)op, value, fold);
            }
        catch (PredicateError e)
            {
            throw new PredicateError(e.message());
            }
        return (Predicate*)0;
        }

    Object* readValue(void) throws
        {
        ws();
        if (i >= n)
            fail("expected a value");
        u8* q = p;
        u8 c = q[i];
        if (c == (u8)'\'' || c == (u8)'"')
            {
            i++;
            String* s = String.withCString("");
            while (true)
                {
                if (i >= n)
                    fail("a string is not closed");
                u8 d = q[i];
                i++;
                if (d == c)
                    break;
                if (d == (u8)'\\' && i < n)
                    {
                    d = q[i];
                    i++;
                    if (d == (u8)'n')
                        d = (u8)$0A;
                    else if (d == (u8)'t')
                        d = (u8)$09;
                    }
                s.appendByte(d);
                }
            return (Object*)s;
            }
        if ((c >= (u8)'0' && c <= (u8)'9') || c == (u8)'-' || c == (u8)'+' || c == (u8)'.')
            {
            u32 start = i;
            i++;
            while (i < n && ((q[i] >= (u8)'0' && q[i] <= (u8)'9') || q[i] == (u8)'.' || q[i] == (u8)'e'
                             || q[i] == (u8)'E' || ((q[i] == (u8)'-' || q[i] == (u8)'+') && (q[i - (u32)1] | (u8)$20) == (u8)'e')))
                i++;
            String* t = String.withBytes(&q[start], i - start);
            if (t.hasPrefix(String.withCString("+")))
                t = t.substringFromByte((u32)1);
            Number* num = Predicate._asNumber(t);
            if (num == 0)
                {
                i = start;
                fail("bad number");
                }
            return (Object*)num;
            }
        if (keyword("TRUE") || keyword("YES"))
            return (Object*)Number.withBool(true);
        if (keyword("FALSE") || keyword("NO"))
            return (Object*)Number.withBool(false);
        if (keyword("NULL") || keyword("NIL"))
            return (Object*)Null.null();
        fail("expected a value");
        return (Object*)0;
        }
    }
