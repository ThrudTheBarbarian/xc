// UXExpression.xc — parse and evaluate an integer expression with variables (NSExpression in shape).
//
// A recursive-descent parser with the usual precedence (comparison < add/sub < mul/div/mod < unary <
// primary) builds a small AST; evaluate() walks it against a set of variable bindings.  Integer-only,
// so it is exact on every backend.  Powers computed columns, a rule value ("price * qty"), or the
// arithmetic half of a light UI scripting layer.  Comparisons yield 1/0.
//
//     UXExpression* e = UXExpression.parse("qty * price + tax");
//     UXBindings* b = new UXBindings(); b.set("qty", 3); b.set("price", 200); b.set("tax", 50);
//     e.evaluate(b);   // 650
#import "Array.xc"

#define EX_NUM 0
#define EX_VAR 1
#define EX_BIN 2
#define EX_NEG 3

#define EXO_ADD 0
#define EXO_SUB 1
#define EXO_MUL 2
#define EXO_DIV 3
#define EXO_MOD 4
#define EXO_EQ 5
#define EXO_NE 6
#define EXO_LT 7
#define EXO_GT 8
#define EXO_LE 9
#define EXO_GE 10

class EXNode : Object
    {
    i32 type;
    i32 num;
    u8* name;
    i32 op;
    EXNode* l;
    EXNode* r;
    void init(void)
        {
        type = (i32)EX_NUM;
        num = (i32)0;
        name = (u8*)"";
        op = (i32)0;
        l = (EXNode*)0;
        r = (EXNode*)0;
        }
    }

    // name -> integer value.
    class UXBindings
    {
    Array<EXNode>* names; // of the name-carrier below
    Array<EXNode>* vals;  // parallel; UXBindVal
    void init(void)
        {
        names = new Array();
        vals = new Array();
        }
    static bool streq(u8* a, u8* b)
        {
        i32 i = (i32)0;
        while (a[i] != (u8)0 && b[i] != (u8)0)
            {
            if (a[i] != b[i])
                {
                return false;
                }
            i = i + (i32)1;
            }
        return a[i] == b[i];
        }
    void set(u8* name, i32 v)
        {
        for (u16 i = (u16)0; i < names.count(); i = i + (u16)1)
            {
            EXNode* nk = (EXNode* ?)names.get(i);
            if (UXBindings.streq(nk.name, name))
                { EXNode* vv = (EXNode* ?)vals.get(i);
                vv.num = v;
                return;
                }
            }
        EXNode* nk = new EXNode();
        nk.name = name;
        names.add(nk);
        EXNode* vv = new EXNode();
        vv.num = v;
        vals.add(vv);
        }
    i32 get(u8* name)
        {
        for (u16 i = (u16)0; i < names.count(); i = i + (u16)1)
            {
            EXNode* nk = (EXNode* ?)names.get(i);
            if (UXBindings.streq(nk.name, name))
                { EXNode* vv = (EXNode* ?)vals.get(i);
                return vv.num;
                }
            }
        return (i32)0; // unbound reads as 0
        }
    }

    class UXExpression
    {
    u8* src;
    i32 pp;
    i32 plen;
    bool ok;
    EXNode* root;

    void init(void)
        {
        src = (u8*)"";
        pp = (i32)0;
        plen = (i32)0;
        ok = true;
        root = (EXNode*)0;
        }

    static UXExpression* parse(u8* s)
        {
        UXExpression* e = new UXExpression();
        e.src = s;
        e.plen = UXExpression.slen(s);
        e.pp = (i32)0;
        e.ok = true;
        e.root = e.parseCompare();
        e.skipWs();
        if (e.pp < e.plen)
            {
            e.ok = false;
            }
        return e;
        }
    bool isValid(void)
        {
        return ok;
        }
    static i32 slen(u8* s)
        {
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }

    // ---- lexer helpers -------------------------------------------------------
    void skipWs(void)
        {
        while (pp < plen && (src[pp] == (u8)' ' || src[pp] == (u8)9))
            {
            pp = pp + (i32)1;
            }
        }
    i32 peek(void)
        {
        self.skipWs();
        return pp < plen ? (i32)src[pp] : (i32)-1;
        }
    static bool isDigit(u8 c)
        {
        return c >= (u8)'0' && c <= (u8)'9';
        }
    static bool isAlpha(u8 c)
        {
        return (c >= (u8)'a' && c <= (u8)'z') || (c >= (u8)'A' && c <= (u8)'Z') || c == (u8)'_';
        }
    static bool isAlnum(u8 c)
        {
        return UXExpression.isAlpha(c) || UXExpression.isDigit(c);
        }

    // ---- grammar -------------------------------------------------------------
    EXNode* parseCompare(void)
        {
        EXNode* left = self.parseAdd();
        i32 c = self.peek();
        i32 op = (i32)-1;
        if (c == (i32)'=' && pp + (i32)1 < plen && src[pp + (i32)1] == (u8)'=')
            {
            op = (i32)EXO_EQ;
            pp = pp + (i32)2;
            }
        else if (c == (i32)'!' && pp + (i32)1 < plen && src[pp + (i32)1] == (u8)'=')
            {
            op = (i32)EXO_NE;
            pp = pp + (i32)2;
            }
        else if (c == (i32)'<' && pp + (i32)1 < plen && src[pp + (i32)1] == (u8)'=')
            {
            op = (i32)EXO_LE;
            pp = pp + (i32)2;
            }
        else if (c == (i32)'>' && pp + (i32)1 < plen && src[pp + (i32)1] == (u8)'=')
            {
            op = (i32)EXO_GE;
            pp = pp + (i32)2;
            }
        else if (c == (i32)'<')
            {
            op = (i32)EXO_LT;
            pp = pp + (i32)1;
            }
        else if (c == (i32)'>')
            {
            op = (i32)EXO_GT;
            pp = pp + (i32)1;
            }
        if (op < (i32)0)
            {
            return left;
            }
        EXNode* right = self.parseAdd();
        return self.bin(op, left, right);
        }
    EXNode* parseAdd(void)
        {
        EXNode* left = self.parseMul();
        while (true)
            {
            i32 c = self.peek();
            if (c == (i32)'+')
                {
                pp = pp + (i32)1;
                left = self.bin((i32)EXO_ADD, left, self.parseMul());
                }
            else if (c == (i32)'-')
                {
                pp = pp + (i32)1;
                left = self.bin((i32)EXO_SUB, left, self.parseMul());
                }
            else
                {
                break;
                }
            }
        return left;
        }
    EXNode* parseMul(void)
        {
        EXNode* left = self.parseUnary();
        while (true)
            {
            i32 c = self.peek();
            if (c == (i32)'*')
                {
                pp = pp + (i32)1;
                left = self.bin((i32)EXO_MUL, left, self.parseUnary());
                }
            else if (c == (i32)'/')
                {
                pp = pp + (i32)1;
                left = self.bin((i32)EXO_DIV, left, self.parseUnary());
                }
            else if (c == (i32)'%')
                {
                pp = pp + (i32)1;
                left = self.bin((i32)EXO_MOD, left, self.parseUnary());
                }
            else
                {
                break;
                }
            }
        return left;
        }
    EXNode* parseUnary(void)
        {
        i32 c = self.peek();
        if (c == (i32)'-')
            {
            pp = pp + (i32)1;
            EXNode* n = new EXNode();
            n.type = (i32)EX_NEG;
            n.l = self.parseUnary();
            return n;
            }
        if (c == (i32)'+')
            {
            pp = pp + (i32)1;
            return self.parseUnary();
            }
        return self.parsePrimary();
        }
    EXNode* parsePrimary(void)
        {
        i32 c = self.peek();
        if (c == (i32)'(')
            {
            pp = pp + (i32)1;
            EXNode* n = self.parseCompare();
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
        if (c >= (i32)'0' && c <= (i32)'9')
            {
            i32 v = (i32)0;
            while (pp < plen && UXExpression.isDigit(src[pp]))
                {
                v = v * (i32)10 + (i32)(src[pp] - (u8)'0');
                pp = pp + (i32)1;
                }
            EXNode* n = new EXNode();
            n.type = (i32)EX_NUM;
            n.num = v;
            return n;
            }
        if (c >= (i32)0 && UXExpression.isAlpha((u8)c))
            {
            i32 start = pp;
            while (pp < plen && UXExpression.isAlnum(src[pp]))
                {
                pp = pp + (i32)1;
                }
            EXNode* n = new EXNode();
            n.type = (i32)EX_VAR;
            n.name = UXExpression.dup(src, start, pp - start);
            return n;
            }
        ok = false;
        EXNode* n = new EXNode();
        n.type = (i32)EX_NUM;
        n.num = (i32)0;
        return n;
        }
    EXNode* bin(i32 op, EXNode* l, EXNode* r)
        {
        EXNode* n = new EXNode();
        n.type = (i32)EX_BIN;
        n.op = op;
        n.l = l;
        n.r = r;
        return n;
        }
    static u8* dup(u8* s, i32 start, i32 len)
        {
        u8* o = new u8[(u32)(len + (i32)1)];
        for (i32 i = (i32)0; i < len; i = i + (i32)1)
            {
            o[i] = s[start + i];
            }
        o[len] = (u8)0;
        return o;
        }

    // ---- evaluation ----------------------------------------------------------
    i32 evaluate(UXBindings* b)
        {
        return self.eval(root, b);
        }
    i32 eval(EXNode* n, UXBindings* b)
        {
        if (n == (EXNode*)0)
            {
            return (i32)0;
            }
        if (n.type == (i32)EX_NUM)
            {
            return n.num;
            }
        if (n.type == (i32)EX_VAR)
            {
            return b == (UXBindings*)0 ? (i32)0 : b.get(n.name);
            }
        if (n.type == (i32)EX_NEG)
            {
            return -self.eval(n.l, b);
            }
        i32 l = self.eval(n.l, b);
        i32 r = self.eval(n.r, b);
        if (n.op == (i32)EXO_ADD)
            {
            return l + r;
            }
        if (n.op == (i32)EXO_SUB)
            {
            return l - r;
            }
        if (n.op == (i32)EXO_MUL)
            {
            return l * r;
            }
        if (n.op == (i32)EXO_DIV)
            {
            return r != (i32)0 ? l / r : (i32)0;
            }
        if (n.op == (i32)EXO_MOD)
            {
            return r != (i32)0 ? l % r : (i32)0;
            }
        if (n.op == (i32)EXO_EQ)
            {
            return l == r ? (i32)1 : (i32)0;
            }
        if (n.op == (i32)EXO_NE)
            {
            return l != r ? (i32)1 : (i32)0;
            }
        if (n.op == (i32)EXO_LT)
            {
            return l < r ? (i32)1 : (i32)0;
            }
        if (n.op == (i32)EXO_GT)
            {
            return l > r ? (i32)1 : (i32)0;
            }
        if (n.op == (i32)EXO_LE)
            {
            return l <= r ? (i32)1 : (i32)0;
            }
        return l >= r ? (i32)1 : (i32)0; // EXO_GE
        }
    }
