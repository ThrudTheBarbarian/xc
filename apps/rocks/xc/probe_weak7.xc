// probe_weak7.xc — WHICH reads of a weak field are mishandled?
//
// Companion to probe_weak6 (bug 036).  Once the root cause was known — a
// returned weak-field read is handed back at +0 while the caller releases it as
// though it owned it — the useful question became how wide the hole is, because
// that decides how wide the fix has to be.
//
// Result, on the compiler as installed 2026-09-04:
//
//   BAD   return weakField;
//   BAD   return b ? weakField : 0;      <- NOT just the direct form
//   ok    Thing* x = weakField; return x;
//   ok    Thing* x = weakField;          (never returned)
//   ok    someMethod(weakField);         (passed as an argument)
//   ok    return (Thing* ?)weakField;    (through a checked cast)
//
// The ternary is the one worth noticing: the defect is not confined to a bare
// field-read in return position, so a fix that pattern-matches `return <field>;`
// would leave it half open.  What matters is the TYPE of the value being
// returned, wherever the expression came from.
//
// Run under MallocScribble=1.
#import <Stdio.xc>
#import "Array.xc"

class Thing : Object
    {
    i32 tag;
    Array<Thing>* kids;
    void init(void)
        {
        tag = (i32)7;
        kids = new Array();
        }
    } class Sink : Object
    {
    void take(Thing* t)
        {
        }
    void init(void)
        {
        }
    } class Holder : Object
    {
    weak : Thing* sel;
    Sink* sink;
    void init(void)
        {
        sel = (Thing*)0;
        sink = new Sink();
        }
    void setSel(Thing* t)
        {
        sel = t;
        }

    // known bad
    Thing* retDirect(void)
        {
        return sel;
        }
    // via an expression
    Thing* retTernary(bool b)
        {
        return b ? sel : (Thing*)0;
        }
    // through a local
    Thing* retLocal(void)
        {
        Thing* x = sel;
        return x;
        }
    // never returned
    void readLocal(void)
        {
        Thing* x = sel;
        if (x == (Thing*)0)
            {
            }
        }
    // as an argument
    void passArg(void)
        {
        sink.take(sel);
        }
    // through a cast
    Thing* retCast(void)
        { return (Thing* ?)sel;
        }
    }

    bool
    dead(Thing* t)
    {
    u64 k = (u64)(pointer)t.kids;
    return k == (u64)0 || (k & (u64)$FF) == (u64)$55 || t.tag != (i32)7;
    }
i32 gBad;
void probe(u8* what, i32 mode)
    {
    Array<Thing>* owner = new Array();
    for (i32 i = (i32)0; i < (i32)8; i = i + (i32)1)
        {
        owner.add(new Thing());
        }
    Holder* h = new Holder();
    for (i32 n = (i32)0; n < (i32)200; n = n + (i32)1)
        {
        h.setSel((Thing* ?)owner.get((u16)(n % (i32)8)));
        if (mode == (i32)0)
            {
            h.retDirect();
            }
        if (mode == (i32)1)
            {
            h.retTernary(true);
            }
        if (mode == (i32)2)
            {
            h.retLocal();
            }
        if (mode == (i32)3)
            {
            h.readLocal();
            }
        if (mode == (i32)4)
            {
            h.passArg();
            }
        if (mode == (i32)5)
            {
            h.retCast();
            }
        for (i32 i = (i32)0; i < (i32)owner.count(); i = i + (i32)1)
            {
            if (dead((Thing* ?)owner.get((u16)i)))
                {
                Stdio.printf("  BAD  %s  -- freed an element after %d calls\n", what, (i16)n);
                gBad = gBad + (i32)1;
                return;
                }
            }
        }
    Stdio.printf("  ok   %s  -- 200 calls, intact\n", what);
    }
void main(void)
    {
    gBad = (i32)0;
    probe((u8*)"return weakField;", (i32)0);
    probe((u8*)"return b ? weakField : 0;", (i32)1);
    probe((u8*)"local = weak; return it;", (i32)2);
    probe((u8*)"local = weak; (no return)", (i32)3);
    probe((u8*)"pass weak as an argument", (i32)4);
    probe((u8*)"return (T*?)weakField;", (i32)5);
    Stdio.printf(gBad == (i32)0 ? "PASS: no read of a weak field over-releases\n"
                                : "FAIL: %d shape(s) over-release\n",
                 (i16)gBad);
    }
