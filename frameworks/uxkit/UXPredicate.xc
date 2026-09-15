// UXPredicate.xc — a predicate tree (NSPredicate / the rule-editor's AND-OR-CONTAINS engine).
//
// Two shapes of node: a COMPARISON (keyPath OP value) and a COMPOUND (AND / OR / NOT of children).
// evaluate() walks the tree against any object that answers the UXEvaluable protocol — one method,
// valueForKey, returning the string value for a key path.  Numeric comparisons (< > <= >=) parse both
// sides as integers; = and != compare as strings; CONTAINS/BEGINSWITH/ENDSWITH are substring tests;
// MATCHES runs an UXRegex.  This is exactly what a rule row ("age > 30", "name contains 'sm'") needs.
//
//     UXPredicate* p = UXPredicate.and(UXPredicate.greaterThan("age", "30"),
//                                      UXPredicate.contains("name", "sm"));
//     p.evaluate(person);   // true if person.age > 30 and "sm" is in person.name
#import "Array.xc"
#import "UXRegex.xc"

// The object under test answers this.  Return "" (or 0) for an absent key.
protocol UXEvaluable
    {
    u8* valueForKey(u8 * key);
    }

#define UXP_COMPARISON 0
#define UXP_COMPOUND 1

#define UXP_EQ 0
#define UXP_NE 1
#define UXP_LT 2
#define UXP_GT 3
#define UXP_LE 4
#define UXP_GE 5
#define UXP_CONTAINS 6
#define UXP_BEGINSWITH 7
#define UXP_ENDSWITH 8
#define UXP_MATCHES 9

#define UXP_AND 0
#define UXP_OR 1
#define UXP_NOT 2

class UXPredicate
    {
    i32 kind;
    // comparison
    u8* key;
    i32 op;
    u8* rhs;
    UXRegex* rx; // compiled for MATCHES
    // compound
    i32 logic;
    Array<UXPredicate>* subs;

    void init(void)
        {
        kind = (i32)UXP_COMPARISON;
        key = (u8*)"";
        op = (i32)UXP_EQ;
        rhs = (u8*)"";
        rx = (UXRegex*)0;
        logic = (i32)UXP_AND;
        subs = new Array();
        }

    // ---- string helpers ------------------------------------------------------
    static i32 slen(u8* s)
        {
        if (s == (u8*)0)
            {
            return (i32)0;
            }
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }
    static bool streq(u8* a, u8* b)
        {
        if (a == (u8*)0)
            {
            a = (u8*)"";
            }
        if (b == (u8*)0)
            {
            b = (u8*)"";
            }
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
    static i32 toInt(u8* s)
        {
        if (s == (u8*)0)
            {
            return (i32)0;
            }
        i32 i = (i32)0;
        i32 sign = (i32)1;
        i32 v = (i32)0;
        while (s[i] == (u8)' ')
            {
            i = i + (i32)1;
            }
        if (s[i] == (u8)'-')
            {
            sign = (i32)-1;
            i = i + (i32)1;
            }
        else if (s[i] == (u8)'+')
            {
            i = i + (i32)1;
            }
        while (s[i] >= (u8)'0' && s[i] <= (u8)'9')
            {
            v = v * (i32)10 + (i32)(s[i] - (u8)'0');
            i = i + (i32)1;
            }
        return v * sign;
        }
    static bool contains(u8* hay, u8* needle)
        {
        i32 hn = UXPredicate.slen(hay);
        i32 nn = UXPredicate.slen(needle);
        if (nn == (i32)0)
            {
            return true;
            }
        for (i32 start = (i32)0; start + nn <= hn; start = start + (i32)1)
            {
            i32 j = (i32)0;
            while (j < nn && hay[start + j] == needle[j])
                {
                j = j + (i32)1;
                }
            if (j == nn)
                {
                return true;
                }
            }
        return false;
        }
    static bool startsWith(u8* hay, u8* pre)
        {
        i32 i = (i32)0;
        while (pre[i] != (u8)0)
            {
            if (hay[i] != pre[i])
                {
                return false;
                }
            i = i + (i32)1;
            }
        return true;
        }
    static bool strEndsWith(u8* hay, u8* suf)
        {
        i32 hn = UXPredicate.slen(hay);
        i32 sn = UXPredicate.slen(suf);
        if (sn > hn)
            {
            return false;
            }
        i32 off = hn - sn;
        for (i32 i = (i32)0; i < sn; i = i + (i32)1)
            {
            if (hay[off + i] != suf[i])
                {
                return false;
                }
            }
        return true;
        }

    // ---- evaluation ----------------------------------------------------------
    bool evaluate(UXEvaluable* obj)
        {
        if (kind == (i32)UXP_COMPOUND)
            {
            if (logic == (i32)UXP_NOT)
                {
                if (subs.count() == (u16)0)
                    {
                    return true;
                    }
                return !((UXPredicate* ?)subs.get((u16)0)).evaluate(obj);
                }
            if (logic == (i32)UXP_AND)
                {
                for (u16 i = (u16)0; i < subs.count(); i = i + (u16)1)
                    {
                    if (!((UXPredicate* ?)subs.get(i)).evaluate(obj))
                        {
                        return false;
                        }
                    }
                return true;
                }
            // OR
            for (u16 i = (u16)0; i < subs.count(); i = i + (u16)1)
                {
                if (((UXPredicate* ?)subs.get(i)).evaluate(obj))
                    {
                    return true;
                    }
                }
            return false;
            }
        // comparison
        u8* lhs = obj.valueForKey(key);
        if (lhs == (u8*)0)
            {
            lhs = (u8*)"";
            }
        if (op == (i32)UXP_EQ)
            {
            return UXPredicate.streq(lhs, rhs);
            }
        if (op == (i32)UXP_NE)
            {
            return !UXPredicate.streq(lhs, rhs);
            }
        if (op == (i32)UXP_LT)
            {
            return UXPredicate.toInt(lhs) < UXPredicate.toInt(rhs);
            }
        if (op == (i32)UXP_GT)
            {
            return UXPredicate.toInt(lhs) > UXPredicate.toInt(rhs);
            }
        if (op == (i32)UXP_LE)
            {
            return UXPredicate.toInt(lhs) <= UXPredicate.toInt(rhs);
            }
        if (op == (i32)UXP_GE)
            {
            return UXPredicate.toInt(lhs) >= UXPredicate.toInt(rhs);
            }
        if (op == (i32)UXP_CONTAINS)
            {
            return UXPredicate.contains(lhs, rhs);
            }
        if (op == (i32)UXP_BEGINSWITH)
            {
            return UXPredicate.startsWith(lhs, rhs);
            }
        if (op == (i32)UXP_ENDSWITH)
            {
            return UXPredicate.strEndsWith(lhs, rhs);
            }
        if (op == (i32)UXP_MATCHES)
            {
            return rx != (UXRegex*)0 && rx.test(lhs);
            }
        return false;
        }

    // ---- builders ------------------------------------------------------------
    static UXPredicate* comparison(u8* key, i32 op, u8* rhs)
        {
        UXPredicate* p = new UXPredicate();
        p.kind = (i32)UXP_COMPARISON;
        p.key = key;
        p.op = op;
        p.rhs = rhs;
        if (op == (i32)UXP_MATCHES)
            {
            p.rx = UXRegex.compile(rhs);
            }
        return p;
        }
    static UXPredicate* equals(u8* k, u8* v)
        {
        return UXPredicate.comparison(k, (i32)UXP_EQ, v);
        }
    static UXPredicate* notEquals(u8* k, u8* v)
        {
        return UXPredicate.comparison(k, (i32)UXP_NE, v);
        }
    static UXPredicate* lessThan(u8* k, u8* v)
        {
        return UXPredicate.comparison(k, (i32)UXP_LT, v);
        }
    static UXPredicate* greaterThan(u8* k, u8* v)
        {
        return UXPredicate.comparison(k, (i32)UXP_GT, v);
        }
    static UXPredicate* lessOrEqual(u8* k, u8* v)
        {
        return UXPredicate.comparison(k, (i32)UXP_LE, v);
        }
    static UXPredicate* greaterOrEqual(u8* k, u8* v)
        {
        return UXPredicate.comparison(k, (i32)UXP_GE, v);
        }
    static UXPredicate* contains_(u8* k, u8* v)
        {
        return UXPredicate.comparison(k, (i32)UXP_CONTAINS, v);
        }
    static UXPredicate* beginsWith(u8* k, u8* v)
        {
        return UXPredicate.comparison(k, (i32)UXP_BEGINSWITH, v);
        }
    static UXPredicate* endsWith(u8* k, u8* v)
        {
        return UXPredicate.comparison(k, (i32)UXP_ENDSWITH, v);
        }
    static UXPredicate* matches(u8* k, u8* v)
        {
        return UXPredicate.comparison(k, (i32)UXP_MATCHES, v);
        }

    static UXPredicate* compound(i32 logic)
        {
        UXPredicate* p = new UXPredicate();
        p.kind = (i32)UXP_COMPOUND;
        p.logic = logic;
        return p;
        }
    void addSub(UXPredicate* s)
        {
        subs.add(s);
        }
    static UXPredicate* and (UXPredicate * a, UXPredicate* b)
        {
        UXPredicate* p = UXPredicate.compound((i32)UXP_AND);
        p.addSub(a);
        p.addSub(b);
        return p;
        }
    static UXPredicate* or (UXPredicate * a, UXPredicate* b)
        {
        UXPredicate* p = UXPredicate.compound((i32)UXP_OR);
        p.addSub(a);
        p.addSub(b);
        return p;
        }
    static UXPredicate * not(UXPredicate * a)
        {
        UXPredicate* p = UXPredicate.compound((i32)UXP_NOT);
        p.addSub(a);
        return p;
        }
    }
