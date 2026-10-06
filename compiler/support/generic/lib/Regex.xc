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
// Regex.xc — regular expressions: match, find, replace, split.
// ===========================================================================
//
//     Regex* re = Regex.compile(String.withCString("(\\w+)@(\\w+)\\.com"));
//     RegexMatch* m = re.firstMatch(String.withCString("mail ada@example.com now"));
//     m.group((u32)1);    // "ada"
//     re.replace(String.withCString("ada@example.com"), String.withCString("$2: $1"));
//                         // "example: ada"
//
// ── The syntax ──────────────────────────────────────────────────────────────
//
//     a  é          a character (UTF-8 in the pattern is one character)
//     .             any character but \n (any at all with dotAll)
//     [abc] [^a-z]  a class, with ranges; \d \w \s and escapes work inside
//     \d \w \s      digit, word character [A-Za-z0-9_], white space
//     \D \W \S      their complements
//     \b \B         a word boundary, and not one
//     ^ $           the start and end (of each line with multiline)
//     \t \n \r \xHH \. \\ …   escapes
//     ( )           a capture group;  (?: ) a group that does not capture
//     a|b           either
//     * + ?         0 or more, 1 or more, 0 or 1
//     {n} {n,} {n,m} counted
//     *? +? ?? {n,m}?   the lazy forms: as few as will do
//
// A character is a whole UTF-8 sequence where the text has one: '.' and a
// class consume all of "é", and [^a] matches it. Case-insensitive matching
// folds ASCII letters only. There are no backreferences or lookaround.
//
// Positions and ranges are byte offsets into the UTF-8 text.
//
// ── Matching ────────────────────────────────────────────────────────────────
//
// The engine is a backtracking virtual machine over a compiled program, with
// an explicit stack (so a long text does not exhaust the native stack) and a
// guard that stops a loop whose body matched nothing from going round again.
// Like other backtracking engines it can take exponential time on patterns
// such as (a*)*b against a long run of a's; each search gives up after
// 2^24 steps and reports no match.
//
// ── Errors ──────────────────────────────────────────────────────────────────
//
// compile throws a RegexError, with the byte offset, for a pattern it cannot
// read.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every heap-capable target except xt6502.

#if ARCH_6502
#error "Regex: not available on xt6502"
#endif

#import "Foundation.xc"
#import "Error.xc"
#import "IndexSet.xc"

class RegexError <Error>
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

// One match: the whole match is group 0.
class RegexMatch : Object
    {
    String* _text;
    i32* _caps;      // start, end per group; -1 when a group took no part
    u32 _groups;     // including group 0

    // The whole match.
    Range* range(void)
        {
        return rangeOfGroup((u32)0);
        }

    // How many capture groups the pattern has (not counting group 0).
    u32 groupCount(void)
        {
        return _groups - (u32)1;
        }

    // Where group n matched; Range(-1, 0) when it took no part (or n is too
    // large).
    Range* rangeOfGroup(u32 n)
        {
        if (n >= _groups)
            return Range.make((i32)-1, (i32)0);
        i32* c = _caps;
        i32 s = c[(u32)2 * n];
        i32 e = c[(u32)2 * n + (u32)1];
        if (s < (i32)0 || e < (i32)0)
            return Range.make((i32)-1, (i32)0);
        return Range.make(s, e - s);
        }

    // The text group n matched; null when it took no part.
    String* group(u32 n)
        {
        Range* r = rangeOfGroup(n);
        if (r.loc < (i32)0)
            return (String*)0;
        return _text.substringBytes((u32)r.loc, (u32)r.len);
        }

    void dealloc(void)
        {
        __arc_release((pointer)_caps);
        }
    }

enum _RxNode = {RN_CHAR, RN_ANY, RN_CLASS, RN_CAT, RN_ALT, RN_REP, RN_GROUP, RN_BOL, RN_EOL, RN_WB, RN_NWB, RN_EMPTY};

class _RxAst
    {
    u8 kind;
    i32 value;      // RN_CHAR: the byte; RN_CLASS: the class index; RN_GROUP: the group, or -1
    _RxAst* a;      // RN_ALT left, RN_REP and RN_GROUP body
    _RxAst* b;      // RN_ALT right
    Array* items;   // RN_CAT
    i32 min;
    i32 max;        // -1: no limit
    bool greedy;
    }

class _RxClass
    {
    IndexSet* set;  // code points
    bool negated;
    }

enum _RxOp = {RO_CHAR, RO_CHARI, RO_ANY, RO_ANYNL, RO_CLASS, RO_SPLIT, RO_JMP, RO_SAVE, RO_MARK, RO_CHECK,
              RO_BOL, RO_BOLM, RO_EOL, RO_EOLM, RO_WB, RO_NWB, RO_MATCH};

class Regex
    {
    String* _pattern;
    u8 _options;
    // The program: three parallel i32 arrays.
    i32* _op;
    i32* _a;
    i32* _b;
    u32 _len;
    u32 _cap;
    Array* _classes;  // _RxClass
    u32 _groups;      // capture groups, not counting group 0
    u32 _marks;       // loop registers
    Regex* _whole;    // the pattern anchored at both ends, made when matches() first needs it
    // While parsing.
    u8* _p;
    u32 _n;
    u32 _i;

    // ── Options ──────────────────────────────────────────────────────────

    static u8 caseInsensitive(void)
        {
        return (u8)1;
        }

    static u8 multiline(void)
        {
        return (u8)2;
        }

    static u8 dotAll(void)
        {
        return (u8)4;
        }

    // ── Compiling ────────────────────────────────────────────────────────

    static Regex* compile(String* pattern) throws
        {
        return Regex.compileWith(pattern, (u8)0);
        }

    // `options` is any of caseInsensitive(), multiline() and dotAll() or'd.
    static Regex* compileWith(String* pattern, u8 options) throws
        {
        if (pattern == 0)
            throw new RegexError(String.withCString("Regex: no pattern"));
        Regex* re = new Regex();
        re._pattern = pattern;
        re._options = options;
        re._classes = new Array();
        re._p = pattern.cString();
        re._n = pattern.byteLength();
        re._i = (u32)0;
        _RxAst* ast = re._parseAlt();
        if (re._i < re._n)
            re._fail(re._p[re._i] == (u8)')' ? "unbalanced ')'" : "unexpected character");
        re._cap = (u32)64;
        re._op = new i32[re._cap];
        re._a = new i32[re._cap];
        re._b = new i32[re._cap];
        re._emit((i32)RO_SAVE, (i32)0, (i32)0);
        re._compile(ast);
        re._emit((i32)RO_SAVE, (i32)1, (i32)0);
        re._emit((i32)RO_MATCH, (i32)0, (i32)0);
        re._p = (u8*)0;
        return re;
        }

    String* pattern(void)
        {
        return _pattern;
        }

    // The number of capture groups.
    u32 groupCount(void)
        {
        return _groups;
        }

    void _fail(u8* why) throws
        {
        String* m = String.withCString("bad pattern at byte ");
        m.append(String.withU32(_i));
        m.appendCString(": ");
        m.appendCString(why);
        throw new RegexError(m);
        }

    static _RxAst* _node(u8 kind)
        {
        _RxAst* n = new _RxAst();
        n.kind = kind;
        return n;
        }

    bool _more(void)
        {
        return _i < _n;
        }

    u8 _peek(void)
        {
        u8* p = _p;
        return _i < _n ? p[_i] : (u8)0;
        }

    _RxAst* _parseAlt(void) throws
        {
        _RxAst* left = _parseCat();
        while (_more() && _peek() == (u8)'|')
            {
            _i++;
            _RxAst* alt = Regex._node((u8)RN_ALT);
            alt.a = left;
            alt.b = _parseCat();
            left = alt;
            }
        return left;
        }

    _RxAst* _parseCat(void) throws
        {
        _RxAst* cat = Regex._node((u8)RN_CAT);
        cat.items = new Array();
        while (_more() && _peek() != (u8)'|' && _peek() != (u8)')')
            cat.items.add(_parseRepeat());
        return cat;
        }

    // Reads decimal digits; -1 if there are none.
    i32 _number(void)
        {
        u8* p = _p;
        i32 v = (i32)-1;
        while (_i < _n && p[_i] >= (u8)'0' && p[_i] <= (u8)'9')
            {
            if (v < (i32)0)
                v = (i32)0;
            if (v < (i32)100000)
                v = v * (i32)10 + (i32)(p[_i] - (u8)'0');
            _i++;
            }
        return v;
        }

    _RxAst* _parseRepeat(void) throws
        {
        u32 atStart = _i;
        _RxAst* atom = _parseAtom();
        while (_more())
            {
            u8 c = _peek();
            i32 min;
            i32 max;
            if (c == (u8)'*')
                {
                min = (i32)0;
                max = (i32)-1;
                _i++;
                }
            else if (c == (u8)'+')
                {
                min = (i32)1;
                max = (i32)-1;
                _i++;
                }
            else if (c == (u8)'?')
                {
                min = (i32)0;
                max = (i32)1;
                _i++;
                }
            else if (c == (u8)'{')
                {
                u32 save = _i;
                _i++;
                min = _number();
                max = min;
                if (min >= (i32)0 && _peek() == (u8)',')
                    {
                    _i++;
                    max = _number();
                    }
                if (min < (i32)0 || _peek() != (u8)'}')
                    {
                    // Not a count: a literal '{', as most engines read it.
                    _i = save;
                    return atom;
                    }
                _i++;
                if (max >= (i32)0 && max < min)
                    _fail("a count's maximum is below its minimum");
                if (min > (i32)1000 || max > (i32)1000)
                    _fail("a count above 1000");
                }
            else
                return atom;
            if (atom.kind == (u8)RN_BOL || atom.kind == (u8)RN_EOL || atom.kind == (u8)RN_WB || atom.kind == (u8)RN_NWB)
                _fail("nothing to repeat");
            _RxAst* rep = Regex._node((u8)RN_REP);
            rep.a = atom;
            rep.min = min;
            rep.max = max;
            rep.greedy = true;
            if (_more() && _peek() == (u8)'?')
                {
                rep.greedy = false;
                _i++;
                }
            atom = rep;
            }
        return atom;
        }

    _RxAst* _parseAtom(void) throws
        {
        u8* p = _p;
        u8 c = p[_i];
        if (c == (u8)'(')
            {
            _i++;
            _RxAst* g = Regex._node((u8)RN_GROUP);
            g.value = (i32)-1;
            if (_i + (u32)1 < _n && p[_i] == (u8)'?' && p[_i + (u32)1] == (u8)':')
                _i = _i + (u32)2;
            else if (_i < _n && p[_i] == (u8)'?')
                _fail("only (?: ) groups are supported");
            else
                {
                _groups = _groups + (u32)1;
                g.value = (i32)_groups;
                }
            g.a = _parseAlt();
            if (!_more() || _peek() != (u8)')')
                _fail("missing ')'");
            _i++;
            return g;
            }
        if (c == (u8)'*' || c == (u8)'+' || c == (u8)'?')
            _fail("nothing to repeat");
        _i++;
        if (c == (u8)'.')
            return Regex._node((u8)RN_ANY);
        if (c == (u8)'^')
            return Regex._node((u8)RN_BOL);
        if (c == (u8)'$')
            return Regex._node((u8)RN_EOL);
        if (c == (u8)'[')
            return _parseClass();
        if (c == (u8)'\\')
            return _parseEscape();
        // A literal, as its whole UTF-8 sequence.
        u32 len = Regex._seqLen(c);
        if (len == (u32)1)
            return Regex._char(c);
        _RxAst* cat = Regex._node((u8)RN_CAT);
        cat.items = new Array();
        cat.items.add(Regex._char(c));
        for (u32 k = (u32)1; k < len && _i < _n; k++)
            {
            cat.items.add(Regex._char(p[_i]));
            _i++;
            }
        return cat;
        }

    static _RxAst* _char(u8 c)
        {
        _RxAst* n = Regex._node((u8)RN_CHAR);
        n.value = (i32)c;
        return n;
        }

    // The length of the UTF-8 sequence a lead byte starts (1 for a stray
    // continuation byte).
    static u32 _seqLen(u8 c)
        {
        if (c < (u8)$C0)
            return (u32)1;
        if (c < (u8)$E0)
            return (u32)2;
        if (c < (u8)$F0)
            return (u32)3;
        return (u32)4;
        }

    // The code point at s[pos] and its length; a bad sequence is one byte.
    static i32 _decode(u8* s, i32 pos, i32 n, i32* len)
        {
        u8 c = s[pos];
        u32 want = Regex._seqLen(c);
        *len = (i32)1;
        if (want == (u32)1 || pos + (i32)want > n)
            return (i32)c;
        i32 cp = want == (u32)2 ? (i32)(c & (u8)$1F) : (want == (u32)3 ? (i32)(c & (u8)$0F) : (i32)(c & (u8)$07));
        for (u32 k = (u32)1; k < want; k++)
            {
            u8 d = s[pos + (i32)k];
            if ((d & (u8)$C0) != (u8)$80)
                return (i32)c;
            cp = (cp << 6) | (i32)(d & (u8)$3F);
            }
        *len = (i32)want;
        return cp;
        }

    _RxAst* _parseEscape(void) throws
        {
        if (!_more())
            _fail("a pattern cannot end in '\\'");
        u8* p = _p;
        u8 c = p[_i];
        _i++;
        if (c == (u8)'b')
            return Regex._node((u8)RN_WB);
        if (c == (u8)'B')
            return Regex._node((u8)RN_NWB);
        _RxClass* cls = new _RxClass();
        cls.set = new IndexSet();
        if (Regex._addPredefined(cls, c))
            return _classNode(cls);
        return Regex._char(_escapedByte(c));
        }

    // The byte an escape stands for (after the '\\' and `c`).
    u8 _escapedByte(u8 c) throws
        {
        if (c == (u8)'t')
            return (u8)$09;
        if (c == (u8)'n')
            return (u8)$0A;
        if (c == (u8)'r')
            return (u8)$0D;
        if (c == (u8)'f')
            return (u8)$0C;
        if (c == (u8)'v')
            return (u8)$0B;
        if (c == (u8)'0')
            return (u8)0;
        if (c == (u8)'x')
            {
            u8* p = _p;
            u8 v = (u8)0;
            for (u32 k = (u32)0; k < (u32)2; k++)
                {
                u8 h = _i < _n ? p[_i] : (u8)0;
                u8 d;
                if (h >= (u8)'0' && h <= (u8)'9')
                    d = h - (u8)'0';
                else if (h >= (u8)'a' && h <= (u8)'f')
                    d = h - (u8)'a' + (u8)10;
                else if (h >= (u8)'A' && h <= (u8)'F')
                    d = h - (u8)'A' + (u8)10;
                else
                    _fail("\\x needs two hex digits");
                v = v * (u8)16 + d;
                _i++;
                }
            return v;
            }
        if ((c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || (c >= (u8)'1' && c <= (u8)'9'))
            _fail("unknown escape");
        return c;
        }

    // \d \w \s and their complements, into `cls`; false for anything else.
    static bool _addPredefined(_RxClass* cls, u8 c)
        {
        u8 lower = c | (u8)$20;
        if (lower != (u8)'d' && lower != (u8)'w' && lower != (u8)'s')
            return false;
        IndexSet* s = new IndexSet();
        if (lower == (u8)'d')
            s.addRange(Range.make((i32)'0', (i32)10));
        else if (lower == (u8)'w')
            {
            s.addRange(Range.make((i32)'0', (i32)10));
            s.addRange(Range.make((i32)'A', (i32)26));
            s.addRange(Range.make((i32)'a', (i32)26));
            s.addIndex((i32)'_');
            }
        else
            {
            s.addRange(Range.make((i32)9, (i32)5));  // \t \n \v \f \r
            s.addIndex((i32)' ');
            }
        if (c == lower)
            cls.set.addIndexes(s);
        else
            {
            // The complement, over every code point.
            IndexSet* all = IndexSet.withRange(Range.make((i32)0, (i32)$110000));
            all.removeIndexes(s);
            cls.set.addIndexes(all);
            }
        return true;
        }

    _RxAst* _classNode(_RxClass* cls)
        {
        if ((_options & Regex.caseInsensitive()) != (u8)0)
            Regex._foldClass(cls.set);
        _classes.add(cls);
        _RxAst* n = Regex._node((u8)RN_CLASS);
        n.value = (i32)(_classes.count() - (u32)1);
        return n;
        }

    // Adds the other case of every ASCII letter in `s`.
    static void _foldClass(IndexSet* s)
        {
        for (i32 c = (i32)'a'; c <= (i32)'z'; c++)
            {
            i32 u = c - (i32)32;
            if (s.containsIndex(c))
                s.addIndex(u);
            else if (s.containsIndex(u))
                s.addIndex(c);
            }
        }

    _RxAst* _parseClass(void) throws
        {
        u8* p = _p;
        _RxClass* cls = new _RxClass();
        cls.set = new IndexSet();
        if (_more() && p[_i] == (u8)'^')
            {
            cls.negated = true;
            _i++;
            }
        bool first = true;
        while (true)
            {
            if (!_more())
                _fail("missing ']'");
            u8 c = p[_i];
            if (c == (u8)']' && !first)
                {
                _i++;
                break;
                }
            first = false;
            i32 lo = _classChar(cls);
            if (lo < (i32)0)
                continue;  // a predefined class went in whole
            if (_i + (u32)1 < _n && p[_i] == (u8)'-' && p[_i + (u32)1] != (u8)']')
                {
                _i++;
                i32 hi = _classChar(cls);
                if (hi < (i32)0)
                    _fail("a range cannot end in a class");
                if (hi < lo)
                    _fail("a range's end is below its start");
                cls.set.addRange(Range.make(lo, hi - lo + (i32)1));
                }
            else
                cls.set.addIndex(lo);
            }
        return _classNode(cls);
        }

    // One character of a class, as a code point; -1 when it was \d, \w or \s
    // (already added).
    i32 _classChar(_RxClass* cls) throws
        {
        u8* p = _p;
        u8 c = p[_i];
        if (c == (u8)'\\')
            {
            _i++;
            if (!_more())
                _fail("missing ']'");
            u8 e = p[_i];
            _i++;
            if (Regex._addPredefined(cls, e))
                return (i32)-1;
            if (e == (u8)'b')
                return (i32)8;
            return (i32)_escapedByte(e);
            }
        i32 len;
        i32 cp = Regex._decode(p, (i32)_i, (i32)_n, &len);
        _i = _i + (u32)len;
        return cp;
        }

    // ── Code generation ──────────────────────────────────────────────────

    u32 _emit(i32 op, i32 a, i32 b)
        {
        if (_len == _cap)
            {
            u32 cap = _cap * (u32)2;
            i32* no = new i32[cap];
            i32* na = new i32[cap];
            i32* nb = new i32[cap];
            i32* oo = _op;
            i32* oa = _a;
            i32* ob = _b;
            for (u32 k = (u32)0; k < _len; k++)
                {
                no[k] = oo[k];
                na[k] = oa[k];
                nb[k] = ob[k];
                }
            __arc_release((pointer)_op);
            __arc_release((pointer)_a);
            __arc_release((pointer)_b);
            _op = no;
            _a = na;
            _b = nb;
            _cap = cap;
            }
        i32* o = _op;
        i32* x = _a;
        i32* y = _b;
        o[_len] = op;
        x[_len] = a;
        y[_len] = b;
        _len = _len + (u32)1;
        return _len - (u32)1;
        }

    void _patch(u32 at, i32 a, i32 b)
        {
        i32* x = _a;
        i32* y = _b;
        x[at] = a;
        y[at] = b;
        }

    // A split preferring `first`.
    void _split(u32 at, i32 first, i32 second)
        {
        _patch(at, first, second);
        }

    void _compile(_RxAst* n) throws
        {
        u8 k = n.kind;
        if (k == (u8)RN_CHAR)
            {
            i32 c = n.value;
            bool fold = (_options & Regex.caseInsensitive()) != (u8)0
                        && ((c >= (i32)'a' && c <= (i32)'z') || (c >= (i32)'A' && c <= (i32)'Z'));
            if (fold)
                _emit((i32)RO_CHARI, c | (i32)32, (i32)0);
            else
                _emit((i32)RO_CHAR, c, (i32)0);
            }
        else if (k == (u8)RN_ANY)
            _emit((_options & Regex.dotAll()) != (u8)0 ? (i32)RO_ANYNL : (i32)RO_ANY, (i32)0, (i32)0);
        else if (k == (u8)RN_CLASS)
            _emit((i32)RO_CLASS, n.value, (i32)0);
        else if (k == (u8)RN_BOL)
            _emit((_options & Regex.multiline()) != (u8)0 ? (i32)RO_BOLM : (i32)RO_BOL, (i32)0, (i32)0);
        else if (k == (u8)RN_EOL)
            _emit((_options & Regex.multiline()) != (u8)0 ? (i32)RO_EOLM : (i32)RO_EOL, (i32)0, (i32)0);
        else if (k == (u8)RN_WB)
            _emit((i32)RO_WB, (i32)0, (i32)0);
        else if (k == (u8)RN_NWB)
            _emit((i32)RO_NWB, (i32)0, (i32)0);
        else if (k == (u8)RN_CAT)
            {
            for (u32 i = (u32)0; i < n.items.count(); i++)
                _compile((_RxAst*)n.items.get(i));
            }
        else if (k == (u8)RN_ALT)
            {
            u32 split = _emit((i32)RO_SPLIT, (i32)0, (i32)0);
            _compile(n.a);
            u32 jmp = _emit((i32)RO_JMP, (i32)0, (i32)0);
            u32 right = _len;
            _compile(n.b);
            _split(split, (i32)(split + (u32)1), (i32)right);
            _patch(jmp, (i32)_len, (i32)0);
            }
        else if (k == (u8)RN_GROUP)
            {
            if (n.value >= (i32)0)
                _emit((i32)RO_SAVE, n.value * (i32)2, (i32)0);
            _compile(n.a);
            if (n.value >= (i32)0)
                _emit((i32)RO_SAVE, n.value * (i32)2 + (i32)1, (i32)0);
            }
        else if (k == (u8)RN_REP)
            {
            if (_len > (u32)1000000)
                _fail("the pattern is too large");
            for (i32 r = (i32)0; r < n.min; r++)
                _compile(n.a);
            if (n.max < (i32)0)
                {
                // loop: split body, out; body: mark; a; check; jmp loop
                u32 loop = _emit((i32)RO_SPLIT, (i32)0, (i32)0);
                u32 reg = _marks;
                _marks = _marks + (u32)1;
                _emit((i32)RO_MARK, (i32)reg, (i32)0);
                _compile(n.a);
                _emit((i32)RO_CHECK, (i32)reg, (i32)0);
                _emit((i32)RO_JMP, (i32)loop, (i32)0);
                if (n.greedy)
                    _split(loop, (i32)(loop + (u32)1), (i32)_len);
                else
                    _split(loop, (i32)_len, (i32)(loop + (u32)1));
                }
            else
                {
                // Each optional copy: split take, out (all to the same end).
                Array* splits = new Array();
                for (i32 r = n.min; r < n.max; r++)
                    {
                    u32 s = _emit((i32)RO_SPLIT, (i32)0, (i32)0);
                    splits.add(Number.withU32(s));
                    _compile(n.a);
                    }
                for (u32 i = (u32)0; i < splits.count(); i++)
                    {
                    u32 s = ((Number*)splits.get(i)).asU32();
                    if (n.greedy)
                        _split(s, (i32)(s + (u32)1), (i32)_len);
                    else
                        _split(s, (i32)_len, (i32)(s + (u32)1));
                    }
                }
            }
        }

    // ── The machine ──────────────────────────────────────────────────────

    static bool _isWord(u8* s, i32 pos, i32 n)
        {
        if (pos < (i32)0 || pos >= n)
            return false;
        u8 c = s[pos];
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z')
               || (c >= (u8)'0' && c <= (u8)'9') || c == (u8)'_';
        }

    // Runs the program from `start`; fills caps (2 per group, -1 unset).
    bool _run(u8* s, i32 n, i32 start, i32* caps, i32* regs, Array* stackHolder)
        {
        u32 slots = (_groups + (u32)1) * (u32)2;
        for (u32 k = (u32)0; k < slots; k++)
            caps[k] = (i32)-1;
        for (u32 k = (u32)0; k < _marks; k++)
            regs[k] = (i32)-1;
        // The backtrack stack: entries of (kind, x, y). Kind 0: a thread at
        // pc x, pos y. Kind 1: caps[x] was y. Kind 2: regs[x] was y.
        u32 cap = (u32)256;
        i32* sk = new i32[cap];
        i32* sx = new i32[cap];
        i32* sy = new i32[cap];
        u32 top = (u32)0;
        i32* op = _op;
        i32* oa = _a;
        i32* ob = _b;
        i32 pc = (i32)0;
        i32 pos = start;
        u32 steps = (u32)0;
        bool matched = false;
        while (true)
            {
            steps++;
            if (steps > (u32)16777216)
                break;
            bool ok = true;
            i32 o = op[pc];
            if (o == (i32)RO_CHAR)
                {
                if (pos < n && (i32)s[pos] == oa[pc])
                    {
                    pos++;
                    pc++;
                    }
                else
                    ok = false;
                }
            else if (o == (i32)RO_CHARI)
                {
                if (pos < n && ((i32)s[pos] | (i32)32) == oa[pc]
                    && ((s[pos] >= (u8)'a' && s[pos] <= (u8)'z') || (s[pos] >= (u8)'A' && s[pos] <= (u8)'Z')))
                    {
                    pos++;
                    pc++;
                    }
                else
                    ok = false;
                }
            else if (o == (i32)RO_ANY || o == (i32)RO_ANYNL)
                {
                if (pos < n && (o == (i32)RO_ANYNL || s[pos] != (u8)$0A))
                    {
                    i32 len;
                    Regex._decode(s, pos, n, &len);
                    pos = pos + len;
                    pc++;
                    }
                else
                    ok = false;
                }
            else if (o == (i32)RO_CLASS)
                {
                ok = false;
                if (pos < n)
                    {
                    i32 len;
                    i32 cp = Regex._decode(s, pos, n, &len);
                    _RxClass* cls = (_RxClass*)_classes.get((u32)oa[pc]);
                    if (cls.set.containsIndex(cp) != cls.negated)
                        {
                        pos = pos + len;
                        pc++;
                        ok = true;
                        }
                    }
                }
            else if (o == (i32)RO_SPLIT || o == (i32)RO_SAVE || o == (i32)RO_MARK)
                {
                if (top == cap)
                    {
                    u32 nc = cap * (u32)2;
                    i32* nk = new i32[nc];
                    i32* nx = new i32[nc];
                    i32* ny = new i32[nc];
                    for (u32 k = (u32)0; k < top; k++)
                        {
                        nk[k] = sk[k];
                        nx[k] = sx[k];
                        ny[k] = sy[k];
                        }
                    __arc_release((pointer)sk);
                    __arc_release((pointer)sx);
                    __arc_release((pointer)sy);
                    sk = nk;
                    sx = nx;
                    sy = ny;
                    cap = nc;
                    }
                if (o == (i32)RO_SPLIT)
                    {
                    sk[top] = (i32)0;
                    sx[top] = ob[pc];
                    sy[top] = pos;
                    pc = oa[pc];
                    }
                else if (o == (i32)RO_SAVE)
                    {
                    sk[top] = (i32)1;
                    sx[top] = oa[pc];
                    sy[top] = caps[oa[pc]];
                    caps[oa[pc]] = pos;
                    pc++;
                    }
                else
                    {
                    sk[top] = (i32)2;
                    sx[top] = oa[pc];
                    sy[top] = regs[oa[pc]];
                    regs[oa[pc]] = pos;
                    pc++;
                    }
                top = top + (u32)1;
                }
            else if (o == (i32)RO_JMP)
                pc = oa[pc];
            else if (o == (i32)RO_CHECK)
                {
                // A loop body that matched nothing does not go round again.
                if (regs[oa[pc]] == pos)
                    ok = false;
                else
                    pc++;
                }
            else if (o == (i32)RO_BOL || o == (i32)RO_BOLM)
                {
                if (pos == (i32)0 || (o == (i32)RO_BOLM && s[pos - (i32)1] == (u8)$0A))
                    pc++;
                else
                    ok = false;
                }
            else if (o == (i32)RO_EOL || o == (i32)RO_EOLM)
                {
                if (pos == n || (o == (i32)RO_EOLM && s[pos] == (u8)$0A))
                    pc++;
                else
                    ok = false;
                }
            else if (o == (i32)RO_WB || o == (i32)RO_NWB)
                {
                bool at = Regex._isWord(s, pos - (i32)1, n) != Regex._isWord(s, pos, n);
                if (at == (o == (i32)RO_WB))
                    pc++;
                else
                    ok = false;
                }
            else
                {
                matched = true;
                break;
                }
            if (!ok)
                {
                // Back to the newest thread, undoing saves on the way.
                bool resumed = false;
                while (top > (u32)0)
                    {
                    top = top - (u32)1;
                    if (sk[top] == (i32)0)
                        {
                        pc = sx[top];
                        pos = sy[top];
                        resumed = true;
                        break;
                        }
                    if (sk[top] == (i32)1)
                        caps[sx[top]] = sy[top];
                    else
                        regs[sx[top]] = sy[top];
                    }
                if (!resumed)
                    break;
                }
            }
        __arc_release((pointer)sk);
        __arc_release((pointer)sx);
        __arc_release((pointer)sy);
        return matched;
        }

    // The first match starting at or after byte `from`, or null.
    RegexMatch* firstMatchFrom(String* text, i32 from)
        {
        if (text == 0)
            return (RegexMatch*)0;
        u8* s = text.cString();
        i32 n = (i32)text.byteLength();
        u32 slots = (_groups + (u32)1) * (u32)2;
        i32* caps = new i32[slots];
        i32* regs = new i32[_marks + (u32)1];
        i32 start = from < (i32)0 ? (i32)0 : from;
        while (start <= n)
            {
            if (_run(s, n, start, caps, regs, (Array*)0))
                {
                RegexMatch* m = new RegexMatch();
                m._text = text;
                m._caps = caps;
                m._groups = _groups + (u32)1;
                __arc_release((pointer)regs);
                return m;
                }
            if (start == n)
                break;
            // On to the next character, not into the middle of one.
            i32 len;
            Regex._decode(s, start, n, &len);
            start = start + len;
            }
        __arc_release((pointer)caps);
        __arc_release((pointer)regs);
        return (RegexMatch*)0;
        }

    // ── Using it ─────────────────────────────────────────────────────────

    RegexMatch* firstMatch(String* text)
        {
        return firstMatchFrom(text, (i32)0);
        }

    // Whether the pattern matches somewhere in `text`.
    bool test(String* text)
        {
        return firstMatch(text) != 0;
        }

    // Whether the pattern matches the whole of `text`: some way of matching
    // it starts at the first byte and ends at the last, even where the
    // first match found would stop short ("a|ab" matches "ab").
    bool matches(String* text)
        {
        if (text == 0)
            return false;
        if (_whole == 0)
            _whole = _anchored();
        return _whole != 0 && _whole.firstMatchFrom(text, (i32)0) != 0;
        }

    Regex* _anchored(void)
        {
        // The same pattern inside ^(?: … )$ with the same options, but
        // multiline off so ^ and $ mean the whole text.
        String* p = String.withCString("^(?:");
        p.append(_pattern);
        p.appendCString(")$");
        Regex* re = (Regex*)0;
        try
            {
            re = Regex.compileWith(p, _options & (u8)$FD);
            }
        catch (RegexError e)
            {
            }
        return re;
        }

    // Every match, left to right, not overlapping. An empty match is followed
    // by a search one character on.
    Array* allMatches(String* text)
        {
        Array* out = new Array();
        if (text == 0)
            return out;
        i32 n = (i32)text.byteLength();
        i32 from = (i32)0;
        while (from <= n)
            {
            RegexMatch* m = firstMatchFrom(text, from);
            if (m == 0)
                break;
            out.add(m);
            Range* r = m.range();
            if (r.len > (i32)0)
                from = r.end();
            else
                {
                if (r.loc >= n)
                    break;
                i32 len;
                Regex._decode(text.cString(), r.loc, n, &len);
                from = r.loc + len;
                }
            }
        return out;
        }

    // `text` with every match replaced by `template`, in which $0 to $9 are
    // the groups (empty for a group that took no part) and $$ is a '$'.
    String* replace(String* text, String* template)
        {
        return _replace(text, template, false);
        }

    String* replaceFirst(String* text, String* template)
        {
        return _replace(text, template, true);
        }

    String* _replace(String* text, String* template, bool once)
        {
        if (text == 0)
            return String.withCString("");
        Array* ms = once ? new Array() : allMatches(text);
        if (once)
            {
            RegexMatch* m = firstMatch(text);
            if (m != 0)
                ms.add(m);
            }
        String* out = String.withCString("");
        i32 at = (i32)0;
        for (u32 k = (u32)0; k < ms.count(); k++)
            {
            RegexMatch* m = (RegexMatch*)ms.get(k);
            Range* r = m.range();
            out.append(text.substringBytes((u32)at, (u32)(r.loc - at)));
            Regex._expand(out, m, template);
            at = r.end();
            }
        out.append(text.substringFromByte((u32)at));
        return out;
        }

    static void _expand(String* out, RegexMatch* m, String* template)
        {
        if (template == 0)
            return;
        u8* t = template.cString();
        u32 n = template.byteLength();
        u32 i = (u32)0;
        while (i < n)
            {
            u8 c = t[i];
            if (c == (u8)'$' && i + (u32)1 < n)
                {
                u8 d = t[i + (u32)1];
                if (d == (u8)'$')
                    {
                    out.appendByte((u8)'$');
                    i = i + (u32)2;
                    continue;
                    }
                if (d >= (u8)'0' && d <= (u8)'9')
                    {
                    String* g = m.group((u32)(d - (u8)'0'));
                    if (g != 0)
                        out.append(g);
                    i = i + (u32)2;
                    continue;
                    }
                }
            out.appendByte(c);
            i++;
            }
        }

    // The pieces of `text` between matches. Empty matches split between
    // characters; a match at the very start or end gives an empty piece there.
    Array* split(String* text)
        {
        Array* out = new Array();
        if (text == 0)
            return out;
        Array* ms = allMatches(text);
        i32 at = (i32)0;
        for (u32 k = (u32)0; k < ms.count(); k++)
            {
            Range* r = ((RegexMatch*)ms.get(k)).range();
            if (r.len == (i32)0 && (r.loc == (i32)0 || r.loc >= (i32)text.byteLength()))
                continue;
            out.add(text.substringBytes((u32)at, (u32)(r.loc - at)));
            at = r.end();
            }
        out.add(text.substringFromByte((u32)at));
        return out;
        }

    // `literal` with every character the syntax treats specially escaped, so
    // it matches itself.
    static String* escape(String* literal)
        {
        String* out = String.withCString("");
        if (literal == 0)
            return out;
        u8* p = literal.cString();
        u8* special = (u8*)"\\^$.|?*+()[]{}";
        for (u32 i = (u32)0; i < literal.byteLength(); i++)
            {
            for (u32 k = (u32)0; special[k] != (u8)0; k++)
                {
                if (p[i] == special[k])
                    {
                    out.appendByte((u8)'\\');
                    break;
                    }
                }
            out.appendByte(p[i]);
            }
        return out;
        }

    void dealloc(void)
        {
        __arc_release((pointer)_op);
        __arc_release((pointer)_a);
        __arc_release((pointer)_b);
        }
    }
