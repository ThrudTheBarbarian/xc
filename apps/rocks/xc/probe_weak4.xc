// probe_weak4.xc — a `weak:` field on a UXView that is ATTACHED TO A WINDOW.
//
// Narrowed from a Rocks crash.  Writing RKEditOverlay.selection (weak) freed
// the model object being assigned; making that one field strong fixes it.  A
// weak field is fine in a plain class, in a deep subclass, and alongside
// callbacks (probe_weak2/3) -- the remaining difference is that the holder is a
// live view in a window's tree.
//
// Run under MallocScribble=1: a freed object reads back as 0x55..
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
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

    // The RKEditOverlay shape: a view with a strong object, a weak object, and
    // callbacks.
    class Overlay : UXView
    {
    Array<Thing>* owned;
    weak : Thing* selection;
    callback picked void(Thing* t);
    callback changed void(Thing* t);
    void init(void)
        {
        super.init();
        owned = new Array();
        selection = (Thing*)0;
        picked = (callback void(Thing * t))0;
        changed = (callback void(Thing * t))0;
        }
    void setSelection(Thing* t)
        {
        selection = t;
        }
    }

    bool
    dead(Thing* t)
    {
    u64 k = (u64)(pointer)t.kids;
    return k == (u64)0 || (k & (u64)$FF) == (u64)$55 || t.tag != (i32)7;
    }

void main(void)
    {
    ux_ak_set_capture((i32)1);
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no AppKit boot\n");
        return;
        }

    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"weak4", UXGeom.make((i16)0, (i16)0, (i16)400, (i16)300), content);

    Overlay* ov = new Overlay();
    content.addSubview(ov, UXGeom.make((i16)0, (i16)0, (i16)400, (i16)300));
    win.tree.finalise();
    win.displayAll();

    // The only strong owner of these, exactly as the document owns the model.
    Array<Thing>* owner = new Array();
    for (i32 i = (i32)0; i < (i32)10; i = i + (i32)1)
        {
        owner.add(new Thing());
        }

    for (i32 n = (i32)0; n < (i32)400; n = n + (i32)1)
        {
        ov.setSelection((Thing* ?)owner.get((u16)(n % (i32)10)));
        for (i32 i = (i32)0; i < (i32)owner.count(); i = i + (i32)1)
            {
            if (dead((Thing* ?)owner.get((u16)i)))
                {
                Stdio.printf("FAIL: element %d freed after %d weak writes — the array still holds it\n",
                             (i16)i, (i16)n);
                return;
                }
            }
        }
    Stdio.printf("PASS: 400 weak writes, every element intact\n");
    }
