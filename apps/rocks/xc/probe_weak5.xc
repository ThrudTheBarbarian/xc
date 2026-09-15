// probe_weak5.xc — bug 036, with a FAT target class.
//
// The one variable probe_weak2/3/4 never changed: they all pointed the weak
// field at a small object.  RKObject, the thing Rocks actually loses, is large
// — many scalars, several object fields, an Array — and is reached through a
// checked cast out of an Array that is its only owner.
#import <Stdio.xc>
#import "Array.xc"

class Payload : Object
    {
    u8* a;
    u8* b;
    u8* c;
    i32 f1;
    i32 f2;
    i32 f3;
    void init(void)
        {
        a = (u8*)"";
        b = (u8*)"";
        c = (u8*)"";
        f1 = (i32)0;
        f2 = (i32)0;
        f3 = (i32)0;
        }
    }

    // Shaped like RKObject: scalars, several optional object payloads, a children
    // array, and a self-referential element type.
    class Fat : Object
    {
    i32 type;
    u8 extType;
    u8 legacyExtType;
    i32 flags;
    i32 state;
    i32 x;
    i32 y;
    i32 w;
    i32 h;
    u8* name;
    u8* text;
    Payload* p1;
    Payload* p2;
    Payload* p3;
    Payload* p4;
    Array<Fat>* children;
    i32 tag;
    void init(void)
        {
        type = (i32)20;
        extType = (u8)0;
        legacyExtType = (u8)0;
        flags = (i32)0;
        state = (i32)0;
        x = (i32)0;
        y = (i32)0;
        w = (i32)0;
        h = (i32)0;
        name = (u8*)0;
        text = (u8*)0;
        p1 = new Payload();
        p2 = (Payload*)0;
        p3 = (Payload*)0;
        p4 = (Payload*)0;
        children = new Array();
        tag = (i32)7;
        }
    }

    // A short-lived object with weak fields, like a UXView being built and torn
    // down: superview and owner are both weak.
    class Churn : Object
    {
    weak : Fat* up;
    weak : Fat* side;
    i32 pad1;
    i32 pad2;
    void init(void)
        {
        up = (Fat*)0;
        side = (Fat*)0;
        pad1 = (i32)0;
        pad2 = (i32)0;
        }
    }

    class Holder : Object
    {
    Fat* strongOne;
    weak : Fat* sel;
    callback a void(Fat* t);
    callback b void(Fat* t);
    callback c void(Fat* t);
    void init(void)
        {
        strongOne = (Fat*)0;
        sel = (Fat*)0;
        a = (callback void(Fat * t))0;
        b = (callback void(Fat * t))0;
        c = (callback void(Fat * t))0;
        }
    void setSel(Fat* o)
        {
        sel = o;
        }
    }

    bool
    dead(Fat* t)
    {
    u64 k = (u64)(pointer)t.children;
    return k == (u64)0 || (k & (u64)$FF) == (u64)$55 || t.tag != (i32)7;
    }

void main(void)
    {
    // A tree, as Rocks has: a root owning children, the root the only owner.
    Fat* root = new Fat();
    for (i32 i = (i32)0; i < (i32)12; i = i + (i32)1)
        {
        Fat* kid = new Fat();
        kid.text = (u8*)"kid";
        root.children.add(kid);
        for (i32 j = (i32)0; j < (i32)2; j = j + (i32)1)
            {
            kid.children.add(new Fat());
            }
        }
    // The ingredient every earlier probe lacked: CHURN.  UXView.superview and
    // .owner are both weak, and every addSubview writes them -- so in Rocks a
    // great many short-lived objects are writing weak fields to a great many
    // different targets, interleaved with the one write that loses the model.
    // Here that is short-lived Churn objects, created and dropped each round,
    // each pointing its own weak field somewhere.
    Holder* h = new Holder();
    for (i32 n = (i32)0; n < (i32)600; n = n + (i32)1)
        {
        Array<Churn>* scratch = new Array();
        for (i32 c = (i32)0; c < (i32)24; c = c + (i32)1)
            {
            Churn* ch = new Churn();
            ch.up = (Fat* ?)root.children.get((u16)(c % (i32)12));
            ch.side = root;
            scratch.add(ch);
            }
        scratch.removeAll(); // and dropped, as a rebuilt pane drops its rows
        Fat* pick = (Fat* ?)root.children.get((u16)(n % (i32)12));
        h.setSel(pick);
        for (i32 i = (i32)0; i < (i32)root.children.count(); i = i + (i32)1)
            {
            Fat* k = (Fat* ?)root.children.get((u16)i);
            if (dead(k))
                {
                Stdio.printf("FAIL: child %d freed after %d weak writes, tree still holds it\n",
                             (i16)i, (i16)n);
                return;
                }
            }
        }
    Stdio.printf("PASS: 600 weak writes at a fat target, tree intact\n");
    }
