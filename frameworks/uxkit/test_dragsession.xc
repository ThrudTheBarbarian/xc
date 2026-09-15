// test_dragsession.xc — UXDragSession: operation negotiation + delivery with a mock drop target.
#import <Stdio.xc>
#import "UXDragSession.xc"
#import "UXPasteboard.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }

// A drop target that only accepts text, wants a COPY, and records what it received.
class TextWell : Object<UXDragDestination>
    {
    u8* dropped;
    bool wantMove;
    void init(void)
        {
        dropped = (u8*)0;
        wantMove = false;
        }
    i32 dragEntered(UXDragSession* s)
        {
        if (!s.hasType((u8*)"public.utf8-plain-text"))
            {
            return (i32)UX_DRAG_NONE;
            }
        return wantMove ? (i32)UX_DRAG_MOVE : (i32)UX_DRAG_COPY;
        }
    bool dragPerform(UXDragSession* s)
        {
        dropped = s.stringForType((u8*)"public.utf8-plain-text");
        return dropped != (u8*)0;
        }
    } bool streq(u8* a, u8* b)
    {
    if (a == (u8*)0 || b == (u8*)0)
        {
        return a == b;
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

void main(void)
    {
    gFails = (i32)0;

    // a text drag that the source allows to be copied
    UXPasteboard* pb = new UXPasteboard();
    pb.writeText((u8*)"dragged text");
    UXDragSession* s = UXDragSession.begin((Object*)0, pb, (i32)UX_DRAG_COPY);

    TextWell* well = new TextWell();
    i32 op = s.enter(well);
    check("negotiated COPY", op, (i32)UX_DRAG_COPY);
    check("canDrop", s.canDrop() ? (i32)1 : (i32)0, (i32)1);
    check("deliver accepted", s.deliver(well) ? (i32)1 : (i32)0, (i32)1);
    check("target got the text", streq(well.dropped, (u8*)"dragged text") ? (i32)1 : (i32)0, (i32)1);

    // target wants MOVE but the source only permits COPY -> masked to none
    well.wantMove = true;
    UXDragSession* s2 = UXDragSession.begin((Object*)0, pb, (i32)UX_DRAG_COPY);
    check("MOVE not allowed -> NONE", s2.enter(well), (i32)UX_DRAG_NONE);
    check("cannot drop", s2.canDrop() ? (i32)1 : (i32)0, (i32)0);
    check("deliver refused", s2.deliver(well) ? (i32)1 : (i32)0, (i32)0);

    // now the source allows MOVE too
    UXDragSession* s3 = UXDragSession.begin((Object*)0, pb, (i32)UX_DRAG_COPY | (i32)UX_DRAG_MOVE);
    check("MOVE now negotiated", s3.enter(well), (i32)UX_DRAG_MOVE);

    // a non-text pasteboard: the well rejects it
    UXPasteboard* img = new UXPasteboard();
    img.setString((u8*)"<png>", (u8*)"public.png");
    UXDragSession* s4 = UXDragSession.begin((Object*)0, img, (i32)UX_DRAG_COPY | (i32)UX_DRAG_MOVE);
    well.wantMove = false;
    check("wrong type -> NONE", s4.enter(well), (i32)UX_DRAG_NONE);
    check("has png type", s4.hasType((u8*)"public.png") ? (i32)1 : (i32)0, (i32)1);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXDragSession — op negotiation, allowed-mask, delivery, type gating.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
