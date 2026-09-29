// test_glseam.xc — the GL seam's ABI and its default state, headless and neutral.
//
// The seam's BEHAVIOUR needs a driver — one that can make a context, and the ones that
// cannot — so that half is gated per backend.  What is gated HERE is the part every backend
// must agree on and nothing else checks: that the two enums still hold the values the driver
// ABI froze (a kind or a GL member renumbered breaks every backend at once, silently), and
// that a GL view with NO CONTEXT is an ordinary drawn view.  That last one is the property
// the whole software path rests on, and it is the one a "is this a GL view?" test gets wrong.
#import <Stdio.xc>
#import "UXView.xc"

i32 gFails;
void ck(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }

// A GL view the way an app writes one: a fallback for the backends that cannot give it a
// context, and nothing else.
class MapView : UXGLView
    {
    i32 painted;
    void init(void)
        {
        super.init();
        painted = (i32)0;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        painted = painted + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;

    // The GL membership is ABI: a renderer picks the entry points it loads from it.
    ck((u8*)"UX_GL_NONE", (i32)UX_GL_NONE, (i32)0);
    ck((u8*)"UX_GL_GLES3", (i32)UX_GL_GLES3, (i32)1);
    ck((u8*)"UX_GL_GL33", (i32)UX_GL_GL33, (i32)2);
    ck((u8*)"UX_GL_WEBGL2", (i32)UX_GL_WEBGL2, (i32)3);

    // The neutral kind is ABI too, and it is a new member: it must not have landed on a
    // value an older .rsc already uses, and it must not be the custom-view kind.
    ck((u8*)"UXKindGLView is 16", (i32)UXKindGLView, (i32)16);
    ck((u8*)"...and is not the custom-view kind", (i32)UXKindGLView == (i32)UXKindView ? (i32)1 : (i32)0, (i32)0);

    // A GL view BEFORE it has a context, which is its state on every backend without GL and
    // in the capture booth.  No context means drawRect is the renderer.
    MapView* v = new MapView();
    ck((u8*)"a GL view reports the GL kind", (i32)v.kind(), (i32)UXKindGLView);
    ck((u8*)"...and owns no context yet", v.ownsGL() ? (i32)1 : (i32)0, (i32)0);
    ck((u8*)"...and has no context to hand a renderer", v.glContext() == (pointer)0 ? (i32)1 : (i32)0, (i32)1);
    ck((u8*)"...and has painted nothing yet", v.painted, (i32)0);

    // A plain view is not a GL view and never becomes one: the seam is opt-in, so the skip in
    // ux_userdraw cannot swallow an ordinary view's drawing by accident.
    UXView* plain = new UXView();
    ck((u8*)"a plain view owns no context", plain.ownsGL() ? (i32)1 : (i32)0, (i32)0);
    ck((u8*)"...and is an ordinary drawn view", (i32)plain.kind(), (i32)UXKindView);

    // The self-painting surface is the second new kind, ABI for the same reason as the GL view:
    // a backend keys its native surface on the kind, so a renumber breaks every backend at once.
    ck((u8*)"UXKindSurface is 17", (i32)UXKindSurface, (i32)17);
    ck((u8*)"...and is not the custom-view kind", (i32)UXKindSurface == (i32)UXKindView ? (i32)1 : (i32)0, (i32)0);
    ck((u8*)"...and is not the GL kind", (i32)UXKindSurface == (i32)UXKindGLView ? (i32)1 : (i32)0, (i32)0);

    // A view asks for its own surface with setOwnSurface, and that call is the whole switch: the
    // view's KIND becomes UXKindSurface.  A backend that can make one (AppKit) realises it
    // natively; one that cannot declines and draws it inline as a UXKindView -- so every one of
    // these three arches, none of which makes a surface, still gets a correct picture.
    UXView* surf = new UXView();
    ck((u8*)"a plain view does not paint in its own surface", surf.paintsInOwnSurface() ? (i32)1 : (i32)0, (i32)0);
    surf.setOwnSurface(true);
    ck((u8*)"setOwnSurface flips the kind", (i32)surf.kind(), (i32)UXKindSurface);
    ck((u8*)"...and the view reports it", surf.paintsInOwnSurface() ? (i32)1 : (i32)0, (i32)1);
    ck((u8*)"...but it is still not a GL view", surf.ownsGL() ? (i32)1 : (i32)0, (i32)0);
    surf.setOwnSurface(false);
    ck((u8*)"...and clears back to an ordinary drawn view", (i32)surf.kind(), (i32)UXKindView);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: GL seam — ABI frozen, and a context-less GL view is an ordinary drawn view.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
