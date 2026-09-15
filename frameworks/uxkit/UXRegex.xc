// UXRegex.xc — a small regular-expression engine (a neutral Foundation facility).
//
// Pattern -> AST (recursive descent) -> a tiny bytecode -> a backtracking VM.  The bytecode is the
// classic six-instruction set (Thompson/Pike): CHAR, ANY, CLASS, split, jmp, match, plus BOL/EOL
// anchors.  SPLIT is the whole story — alternation and every quantifier compile to a split that the
// VM tries one way and, on failure, backtracks to the other.
//
// Supported: literals, '.', character classes [abc] [^a-z] with ranges, the predefined classes
// \d \w \s (and \D \W \S), escapes (\. \* \\ …), anchors ^ $, groups ( ), alternation |, and the
// quantifiers * + ? (greedy).  No captures/backreferences yet — this is a matcher, not a parser.
//
//     UXRegex* re = UXRegex.compile("^\\d+-[a-z]+$");
//     re.matches("42-hello")   // true (whole string)
//     re.test("x 7 y")         // does "\\d" occur anywhere?  -> search
#import "Array.xc"
#import "UXIndexSet.xc"

// A character class is just a set of byte values (reuse UXIndexSet), plus a negation flag.
class UXCharClass : Object
    {
    UXIndexSet* set;
    bool negated;
    void init(void)
        {
        set = new UXIndexSet();
        negated = false;
        }
    void addChar(i32 c)
        {
        set.addIndex(c);
        }
    void addRange(i32 lo, i32 hi)
        {
        if (hi >= lo)
            {
            set.addRange(lo, hi - lo + (i32)1);
            }
        }
    bool contains(i32 c)
        {
        bool hit = set.containsIndex(c);
        return negated ? !hit : hit;
        }
    }

// ---- AST -------------------------------------------------------------------
#define RN_CHAR 0
#define RN_ANY 1
#define RN_CLASS 2
#define RN_CONCAT 3
#define RN_ALT 4
#define RN_STAR 5
#define RN_PLUS 6
#define RN_QUEST 7
#define RN_BOL 8
#define RN_EOL 9

    class RXNode : Object
    {
    i32 type;
    i32 ch;
    UXCharClass* cls;
    Array<RXNode>* kids;
    void init(void)
        {
        type = (i32)0;
        ch = (i32)0;
        cls = (UXCharClass*)0;
        kids = new Array();
        }
    }

// ---- bytecode --------------------------------------------------------------
#define OP_CHAR 0
#define OP_ANY 1
#define OP_CLASS 2
#define OP_MATCH 3
#define OP_JMP 4
#define OP_SPLIT 5
#define OP_BOL 6
#define OP_EOL 7

    class RXInstr : Object
    {
    i32 op;
    i32 a; // char, or jump/split target
    i32 b; // second split target
    UXCharClass* cls;
    void init(void)
        {
        op = (i32)0;
        a = (i32)0;
        b = (i32)0;
        cls = (UXCharClass*)0;
        }
    }

    class UXRegex
    {
    // parse state
    u8* pat;
    i32 pp;
    i32 plen;
    bool ok; // false if the pattern failed to parse
    // program
    Array<RXInstr>* prog; // of RXInstr
    // match state
    u8* subj;
    i32 slen;
    bool anchoredEnd; // matches(): the match must reach the end of the subject
    i32 matchEnd;

    void init(void)
        {
        pat = (u8*)0;
        pp = (i32)0;
        plen = (i32)0;
        ok = true;
        prog = new Array();
        subj = (u8*)0;
        slen = (i32)0;
        anchoredEnd = false;
        matchEnd = (i32)0;
        }

    static UXRegex* compile(u8* pattern)
        {
        UXRegex* re = new UXRegex();
        re.compilePattern(pattern);
        return re;
        }
    bool isValid(void)
        {
        return ok;
        }

    // ---- lexer helpers -------------------------------------------------------
    i32 peek(void)
        {
        return pp < plen ? (i32)pat[pp] : (i32)-1;
        }
    i32 slen_of(u8* s)
        {
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }

    void compilePattern(u8* pattern)
        {
        pat = pattern;
        pp = (i32)0;
        plen = self.slen_of(pattern);
        ok = true;
        prog = new Array();
        RXNode* ast = self.parseAlt();
        // trailing junk (e.g. an unmatched ')')
        if (pp < plen)
            {
            ok = false;
            }
        self.emit(ast);
        self.append(OP_MATCH, (i32)0, (i32)0);
        }

    // ---- recursive-descent parser -------------------------------------------
    RXNode* node(i32 type)
        {
        RXNode* n = new RXNode();
        n.type = type;
        return n;
        }

    RXNode* parseAlt(void)
        {
        RXNode* left = self.parseConcat();
        if (self.peek() != (i32)'|')
            {
            return left;
            }
        RXNode* alt = self.node(RN_ALT);
        alt.kids.add(left);
        while (self.peek() == (i32)'|')
            {
            pp = pp + (i32)1;
            alt.kids.add(self.parseConcat());
            }
        return alt;
        }
    RXNode* parseConcat(void)
        {
        RXNode* cat = self.node(RN_CONCAT);
        while (pp < plen && self.peek() != (i32)'|' && self.peek() != (i32)')')
            {
            cat.kids.add(self.parseRepeat());
            }
        return cat;
        }
    RXNode* parseRepeat(void)
        {
        RXNode* atom = self.parseAtom();
        i32 c = self.peek();
        if (c == (i32)'*')
            {
            pp = pp + (i32)1;
            return self.wrap(RN_STAR, atom);
            }
        if (c == (i32)'+')
            {
            pp = pp + (i32)1;
            return self.wrap(RN_PLUS, atom);
            }
        if (c == (i32)'?')
            {
            pp = pp + (i32)1;
            return self.wrap(RN_QUEST, atom);
            }
        return atom;
        }
    RXNode* wrap(i32 type, RXNode* inner)
        {
        RXNode* n = self.node(type);
        n.kids.add(inner);
        return n;
        }

    RXNode* parseAtom(void)
        {
        i32 c = self.peek();
        if (c == (i32)'(')
            {
            pp = pp + (i32)1;
            RXNode* n = self.parseAlt();
            if (self.peek() == (i32)')')
                {
                pp = pp + (i32)1;
                }
            else
                {
                ok = false;
                }
            return n;
            }
        if (c == (i32)'[')
            {
            return self.parseClass();
            }
        if (c == (i32)'.')
            {
            pp = pp + (i32)1;
            return self.node(RN_ANY);
            }
        if (c == (i32)'^')
            {
            pp = pp + (i32)1;
            return self.node(RN_BOL);
            }
        if (c == (i32)'$')
            {
            pp = pp + (i32)1;
            return self.node(RN_EOL);
            }
        if (c == (i32)'\\')
            {
            pp = pp + (i32)1;
            return self.parseEscape();
            }
        pp = pp + (i32)1;
        RXNode* n = self.node(RN_CHAR);
        n.ch = c;
        return n;
        }

    // \d \w \s and negations -> a class; anything else -> that literal char.
    RXNode* parseEscape(void)
        {
        i32 c = self.peek();
        pp = pp + (i32)1;
        if (c == (i32)'d' || c == (i32)'D')
            {
            return self.predefined((i32)'d', c == (i32)'D');
            }
        if (c == (i32)'w' || c == (i32)'W')
            {
            return self.predefined((i32)'w', c == (i32)'W');
            }
        if (c == (i32)'s' || c == (i32)'S')
            {
            return self.predefined((i32)'s', c == (i32)'S');
            }
        i32 lit = c;
        if (c == (i32)'n')
            {
            lit = (i32)10;
            }
        if (c == (i32)'t')
            {
            lit = (i32)9;
            }
        if (c == (i32)'r')
            {
            lit = (i32)13;
            }
        RXNode* n = self.node(RN_CHAR);
        n.ch = lit;
        return n;
        }
    RXNode* predefined(i32 kind, bool negated)
        {
        UXCharClass* cc = new UXCharClass();
        cc.negated = negated;
        if (kind == (i32)'d')
            {
            cc.addRange((i32)'0', (i32)'9');
            }
        else if (kind == (i32)'w')
            {
            cc.addRange((i32)'0', (i32)'9');
            cc.addRange((i32)'a', (i32)'z');
            cc.addRange((i32)'A', (i32)'Z');
            cc.addChar((i32)'_');
            }
        // \s
        else
            {
            cc.addChar((i32)' ');
            cc.addChar((i32)9);
            cc.addChar((i32)10);
            cc.addChar((i32)13);
            cc.addChar((i32)12);
            cc.addChar((i32)11);
            }
        RXNode* n = self.node(RN_CLASS);
        n.cls = cc;
        return n;
        }
    RXNode* parseClass(void)
        {
        pp = pp + (i32)1; // consume '['
        UXCharClass* cc = new UXCharClass();
        if (self.peek() == (i32)'^')
            {
            cc.negated = true;
            pp = pp + (i32)1;
            }
        while (pp < plen && self.peek() != (i32)']')
            {
            i32 lo = self.classChar();
            if (self.peek() == (i32)'-' && pp + (i32)1 < plen && (i32)pat[pp + (i32)1] != (i32)']')
                {
                pp = pp + (i32)1; // consume '-'
                i32 hi = self.classChar();
                cc.addRange(lo, hi);
                }
            else
                {
                cc.addChar(lo);
                }
            }
        if (self.peek() == (i32)']')
            {
            pp = pp + (i32)1;
            }
        else
            {
            ok = false;
            }
        RXNode* n = self.node(RN_CLASS);
        n.cls = cc;
        return n;
        }
    // one character inside [...], honouring a backslash escape.
    i32 classChar(void)
        {
        i32 c = self.peek();
        pp = pp + (i32)1;
        if (c == (i32)'\\' && pp < plen)
            {
            i32 e = self.peek();
            pp = pp + (i32)1;
            if (e == (i32)'n')
                {
                return (i32)10;
                }
            if (e == (i32)'t')
                {
                return (i32)9;
                }
            if (e == (i32)'r')
                {
                return (i32)13;
                }
            return e;
            }
        return c;
        }

    // ---- emit (AST -> bytecode, with backpatching) ---------------------------
    i32 append(i32 op, i32 a, i32 b)
        {
        RXInstr* ins = new RXInstr();
        ins.op = op;
        ins.a = a;
        ins.b = b;
        prog.add(ins);
        return (i32)prog.count() - (i32)1;
        }
    RXInstr* at(i32 i)
        { return (RXInstr* ?)prog.get((u16)i);
        }
    i32 here(void)
        {
        return (i32)prog.count();
        }

    void emit(RXNode* n)
        {
        i32 t = n.type;
        if (t == RN_CHAR)
            {
            self.append(OP_CHAR, n.ch, (i32)0);
            return;
            }
        if (t == RN_ANY)
            {
            self.append(OP_ANY, (i32)0, (i32)0);
            return;
            }
        if (t == RN_BOL)
            {
            self.append(OP_BOL, (i32)0, (i32)0);
            return;
            }
        if (t == RN_EOL)
            {
            self.append(OP_EOL, (i32)0, (i32)0);
            return;
            }
        if (t == RN_CLASS)
            {
            i32 idx = self.append(OP_CLASS, (i32)0, (i32)0);
            self.at(idx).cls = n.cls;
            return;
            }
        if (t == RN_CONCAT)
            {
            for (u16 i = (u16)0; i < n.kids.count(); i = i + (u16)1)
                { self.emit((RXNode* ?)n.kids.get(i));
                }
            return;
            }
        if (t == RN_ALT)
            {
            Array<RXInstr>* jmps = new Array();
            u16 cnt = n.kids.count();
            for (u16 i = (u16)0; i < cnt; i = i + (u16)1)
                {
                if (i < cnt - (u16)1)
                    {
                    i32 sp = self.append(OP_SPLIT, (i32)0, (i32)0);
                    self.at(sp).a = self.here(); // this alternative
                    self.emit((RXNode* ?)n.kids.get(i));
                    i32 jm = self.append(OP_JMP, (i32)0, (i32)0); // to the end after a hit
                    RXInstr* ji = self.at(jm);
                    jmps.add(ji);
                    self.at(sp).b = self.here(); // else try the next alternative
                    }
                else
                    {
                    self.emit((RXNode* ?)n.kids.get(i));         // last one: no split
                    }
                }
            i32 end = self.here();
            for (u16 i = (u16)0; i < jmps.count(); i = i + (u16)1)
                {
                RXInstr* ji = (RXInstr* ?)jmps.get(i);
                ji.a = end;
                }
            return;
            }
        if (t == RN_STAR)
            {
            i32 l1 = self.here();
            i32 sp = self.append(OP_SPLIT, (i32)0, (i32)0);
            self.at(sp).a = self.here();
            self.emit((RXNode* ?)n.kids.get((u16)0));
            self.append(OP_JMP, l1, (i32)0);
            self.at(sp).b = self.here();
            return;
            }
        if (t == RN_PLUS)
            {
            i32 l1 = self.here();
            self.emit((RXNode* ?)n.kids.get((u16)0));
            i32 sp = self.append(OP_SPLIT, l1, (i32)0);
            self.at(sp).b = self.here();
            return;
            }
        if (t == RN_QUEST)
            {
            i32 sp = self.append(OP_SPLIT, (i32)0, (i32)0);
            self.at(sp).a = self.here();
            self.emit((RXNode* ?)n.kids.get((u16)0));
            self.at(sp).b = self.here();
            return;
            }
        }

    // ---- backtracking VM -----------------------------------------------------
    bool run(i32 pc, i32 pos)
        {
        while (true)
            {
            RXInstr* ins = self.at(pc);
            i32 op = ins.op;
            if (op == OP_CHAR)
                {
                if (pos < slen && (i32)subj[pos] == ins.a)
                    {
                    pc = pc + (i32)1;
                    pos = pos + (i32)1;
                    }
                else
                    {
                    return false;
                    }
                }
            else if (op == OP_ANY)
                {
                if (pos < slen)
                    {
                    pc = pc + (i32)1;
                    pos = pos + (i32)1;
                    }
                else
                    {
                    return false;
                    }
                }
            else if (op == OP_CLASS)
                {
                if (pos < slen && ins.cls.contains((i32)subj[pos]))
                    {
                    pc = pc + (i32)1;
                    pos = pos + (i32)1;
                    }
                else
                    {
                    return false;
                    }
                }
            else if (op == OP_BOL)
                {
                if (pos == (i32)0 || (i32)subj[pos - (i32)1] == (i32)10)
                    {
                    pc = pc + (i32)1;
                    }
                else
                    {
                    return false;
                    }
                }
            else if (op == OP_EOL)
                {
                if (pos == slen || (i32)subj[pos] == (i32)10)
                    {
                    pc = pc + (i32)1;
                    }
                else
                    {
                    return false;
                    }
                }
            else if (op == OP_JMP)
                {
                pc = ins.a;
                }
            else if (op == OP_SPLIT)
                {
                // greedy: first branch, then backtrack
                if (self.run(ins.a, pos))
                    {
                    return true;
                    }
                pc = ins.b;
                }
            // OP_MATCH
            else
                {
                if (!anchoredEnd || pos == slen)
                    {
                    matchEnd = pos;
                    return true;
                    }
                return false;
                }
            }
        return false;
        }

    // ---- public matching -----------------------------------------------------
    // Whole-string match (anchored both ends).
    bool matches(u8* s)
        {
        if (!ok)
            {
            return false;
            }
        subj = s;
        slen = self.slen_of(s);
        anchoredEnd = true;
        return self.run((i32)0, (i32)0);
        }
    // Does the pattern occur anywhere?  (unanchored search)
    bool test(u8* s)
        {
        return self.search(s) >= (i32)0;
        }
    // First match start index, or -1.  matchEnd holds one-past-end of that match afterwards.
    i32 search(u8* s)
        {
        if (!ok)
            {
            return (i32)-1;
            }
        subj = s;
        slen = self.slen_of(s);
        anchoredEnd = false;
        for (i32 start = (i32)0; start <= slen; start = start + (i32)1)
            {
            if (self.run((i32)0, start))
                {
                return start;
                }
            }
        return (i32)-1;
        }
    // valid right after a successful search()/matches()
    i32 matchLength(void)
        {
        return matchEnd;
        }
    }
