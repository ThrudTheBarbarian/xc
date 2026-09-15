// probe_weak6.xc — bug 036, reduced at last: RETURNING a weak field.
//
// The shape none of probe_weak2..5 had.  They all WROTE weak fields; not one of
// them returned a weak field from a method, which is what Rocks does on every
// press (RKEditOverlay.currentSelection).
//
// A returned weak-field read is handed back at +0, borrowed, while the caller
// treats a class-pointer return as owned and releases it — so every call
// decrements an object nobody gave it a reference to.
//
// Run under MallocScribble=1: freed memory reads back as 0x55..
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
    }

    class Holder : Object
    {
    weak : Thing* sel;
    Thing* strongSel;
    void init(void)
        {
        sel = (Thing*)0;
        strongSel = (Thing*)0;
        }
    void setSel(Thing* t)
        {
        sel = t;
        }
    // <-- the suspect
    Thing* getSel(void)
        {
        return sel;
        }
    void setStrong(Thing* t)
        {
        strongSel = t;
        }
    // the control case
    Thing* getStrong(void)
        {
        return strongSel;
        }
    }

    bool
    dead(Thing* t)
    {
    u64 k = (u64)(pointer)t.kids;
    return k == (u64)0 || (k & (u64)$FF) == (u64)$55 || t.tag != (i32)7;
    }
i32 gFails;
void run(u8* what, bool useWeak)
    {
    Array<Thing>* owner = new Array(); // the ONLY strong owner
    for (i32 i = (i32)0; i < (i32)8; i = i + (i32)1)
        {
        owner.add(new Thing());
        }
    Holder* h = new Holder();
    for (i32 n = (i32)0; n < (i32)300; n = n + (i32)1)
        {
        Thing* pick = (Thing* ?)owner.get((u16)(n % (i32)8));
        if (useWeak)
            {
            h.setSel(pick);
            }
        else
            {
            h.setStrong(pick);
            }
        Thing* got = useWeak ? h.getSel() : h.getStrong(); // the returning read
        if ((pointer)got == (pointer)0)
            {
            Stdio.printf("  FAIL %s: getter lost it at %d\n", what, (i16)n);
            gFails = gFails + (i32)1;
            return;
            }
        for (i32 i = (i32)0; i < (i32)owner.count(); i = i + (i32)1)
            {
            if (dead((Thing* ?)owner.get((u16)i)))
                {
                Stdio.printf("  FAIL %s: element %d freed after %d calls — the array still holds it\n",
                             what, (i16)i, (i16)n);
                gFails = gFails + (i32)1;
                return;
                }
            }
        }
    Stdio.printf("  ok   %s: 300 calls, every element intact\n", what);
    }

void main(void)
    {
    gFails = (i32)0;
    run((u8*)"returning a STRONG field", false);
    run((u8*)"returning a WEAK field  ", true);
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: a returned weak field is not over-released\n");
        }
    else
        {
        Stdio.printf("FAIL: %d case(s)\n", (i16)gFails);
        }
    }
