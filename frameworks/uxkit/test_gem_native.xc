// test_gem_native.xc — GEM draws its own controls (the gem-native gate, hostgem/run_native.sh and
// run_xtos_native.sh).  A check box, two radio buttons, a slider and a popup are GEM objects
// (G_CHECKBOX, G_RADIO, G_SLIDER, G_POPUP) that the AES draws from the state the driver copies in:
// none of the toolkit's drawRects runs, and the window's snapshot changes where the state does.  A
// press on the slider sets the value that puts GEM's knob under it.  A scroll view's bar is a
// G_SCROLL, its thumb drawn where the toolkit's press handling has it.  -D NATIVE_HALF halves the
// layout for qemu's 200x120 plane.
#import <Stdio.xc>
#import "UXGemDriver.xc"
#import "UXBoot.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXSlider.xc"
#import "UXPopUpButton.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXImage.xc"
#import "Data.xc"
#import "UXFileIO.xc"
#import "UXString.xc" // UXStr, the PPM header
u8* getenv(u8* name);

i32 gFails;
void ck(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }
i32 d(i32 n)
    {
#if NATIVE_HALF
    return n / (i32)2;
#else
    return n;
#endif
    }
UXRect r(i32 x, i32 y, i32 w, i32 h)
    {
    return UXGeom.make((i16)d(x), (i16)d(y), (i16)d(w), (i16)d(h));
    }

// each control counts its drawRect: GEM drawing it means the toolkit never does
i32 gToolkitDraws;
class Check : UXCheckbox
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        gToolkitDraws = gToolkitDraws + (i32)1;
        }
    }
class Radio : UXRadioButton
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        gToolkitDraws = gToolkitDraws + (i32)1;
        }
    }
class Slide : UXSlider
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        gToolkitDraws = gToolkitDraws + (i32)1;
        }
    }
class Pop : UXPopUpButton
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        gToolkitDraws = gToolkitDraws + (i32)1;
        }
    }
class Back : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)255, (i32)255, (i32)255);
        }
    }

UXWindow* gWin;
i32 typeOf(UXView* v)
    {
    return (i32)((OBJECT*)gWin.tree.objects())[(i32)v.index].ob_type;
    }
// how many pixels of a region differ between two pictures of the window
i32 diff(UXImage* a, UXImage* b, i32 x0, i32 y0, i32 w, i32 h)
    {
    i32 n = (i32)0;
    for (i32 y = y0; y < y0 + h; y = y + (i32)1)
        {
        for (i32 x = x0; x < x0 + w; x = x + (i32)1)
            {
            if ((a.px[y * a.w + x] & (u32)$FFFFFF) != (b.px[y * b.w + x] & (u32)$FFFFFF))
                {
                n = n + (i32)1;
                }
            }
        }
    return n;
    }
// how many pixels of a region are not the window's white
i32 inked(UXImage* a, i32 x0, i32 y0, i32 w, i32 h)
    {
    i32 n = (i32)0;
    for (i32 y = y0; y < y0 + h; y = y + (i32)1)
        {
        for (i32 x = x0; x < x0 + w; x = x + (i32)1)
            {
            if ((a.px[y * a.w + x] & (u32)$FFFFFF) != (u32)$FFFFFF)
                {
                n = n + (i32)1;
                }
            }
        }
    return n;
    }
UXImage* shot(void)
    {
    gWin.displayAll();
    return gWin.snapshot((UXRect*)0);
    }
// a press and release as the app's own code hands them in: replayed input, which a modal drag (the
// slider's) does not follow to the live pointer
void press(i32 x, i32 y)
    {
    gInputReplay = true;
    UXEvent* e = new UXEvent();
    e.kind = (u8)UXEventMouseDown;
    e.x = (i16)x;
    e.y = (i16)y;
    e.handle = gWin.handle;
    gWin.dispatchMouse(e);
    UXEvent* u = new UXEvent();
    u.kind = (u8)UXEventMouseUp;
    u.x = (i16)x;
    u.y = (i16)y;
    u.handle = gWin.handle;
    gWin.dispatchMouseUp(u);
    gInputReplay = false;
    }

void checks(void)
    {
    Back* back = new Back();
    gWin = new UXWindow();
    gWin.open((u8*)"native", UXGeom.make((i16)40, (i16)40, (i16)d((i32)360), (i16)d((i32)220)), back);
    gApp.addWindow(gWin);
    Check* cb = new Check();
    cb.setTitle((u8*)"Wrap");
    back.addSubview(cb, r((i32)20, (i32)20, (i32)140, (i32)24));
    UXRadioGroup* grp = new UXRadioGroup();
    Radio* ra = new Radio();
    ra.setTitle((u8*)"Left");
    Radio* rb = new Radio();
    rb.setTitle((u8*)"Right");
    back.addSubview(ra, r((i32)20, (i32)56, (i32)140, (i32)24));
    back.addSubview(rb, r((i32)20, (i32)88, (i32)140, (i32)24));
    grp.add(ra);
    grp.add(rb);
    grp.select(ra);
    Slide* sl = new Slide();
    sl.setRange((i32)0, (i32)100);
    sl.setValue((i32)0);
    back.addSubview(sl, r((i32)20, (i32)130, (i32)300, (i32)24));
    Pop* pop = new Pop();
    pop.addItem((u8*)"One", (i32)1);
    pop.addItem((u8*)"Seventeen", (i32)2);
    pop.selectItem((i32)0);
    back.addSubview(pop, r((i32)180, (i32)20, (i32)150, (i32)26));
    UXScrollView* sv = new UXScrollView();
    back.addSubview(sv, r((i32)180, (i32)56, (i32)150, (i32)70));
    sv.setDocumentHeight((i32)600);
    gToolkitDraws = (i32)0;

    ck((u8*)"the check box is a G_CHECKBOX", typeOf(cb) == (i32)G_CHECKBOX);
    ck((u8*)"the radio buttons are G_RADIOs", typeOf(ra) == (i32)G_RADIO && typeOf(rb) == (i32)G_RADIO);
    ck((u8*)"the slider is a G_SLIDER", typeOf(sl) == (i32)G_SLIDER);
    ck((u8*)"the popup is a G_POPUP", typeOf(pop) == (i32)G_POPUP);

    UXImage* a = shot();
    if (a == (UXImage*)0)
        {
        ck((u8*)"the window snapshots", false);
        return;
        }
    ck((u8*)"GEM draws the check box", inked(a, d((i32)20), d((i32)20), d((i32)24), d((i32)24)) > d((i32)40));
    ck((u8*)"...and its label", inked(a, d((i32)50), d((i32)20), d((i32)100), d((i32)24)) > d((i32)20));
    ck((u8*)"GEM draws the radio buttons", inked(a, d((i32)20), d((i32)56), d((i32)24), d((i32)24)) > d((i32)40) && inked(a, d((i32)20), d((i32)88), d((i32)24), d((i32)24)) > d((i32)40));
    ck((u8*)"GEM draws the slider", inked(a, d((i32)20), d((i32)130), d((i32)300), d((i32)24)) > d((i32)100));
    ck((u8*)"GEM draws the popup", inked(a, d((i32)180), d((i32)20), d((i32)150), d((i32)26)) > d((i32)200));

    // the state, as GEM draws it
    cb.setChecked(true);
    UXImage* b = shot();
    ck((u8*)"checking the box changes GEM's box", diff(a, b, d((i32)20), d((i32)20), d((i32)24), d((i32)24)) > (i32)4);
    ck((u8*)"...and nothing else", diff(a, b, d((i32)180), (i32)0, d((i32)180), d((i32)220)) == (i32)0);
    press(d((i32)30), d((i32)100));
    ck((u8*)"a press on the second radio button selects it", rb.isSelected() && !ra.isSelected());
    UXImage* c = shot();
    ck((u8*)"...and GEM moves the dot", diff(b, c, d((i32)20), d((i32)56), d((i32)24), d((i32)24)) > (i32)4 && diff(b, c, d((i32)20), d((i32)88), d((i32)24), d((i32)24)) > (i32)4);
    pop.selectItem((i32)1);
    UXImage* e = shot();
    ck((u8*)"selecting an item changes GEM's popup title", diff(c, e, d((i32)180), d((i32)20), d((i32)150), d((i32)26)) > (i32)10);

    // a press on the slider three quarters along its knob's travel: the value that puts GEM's knob
    // there, and GEM's knob drawn there
    theme_slice* k = (theme_slice*)theme_find((pointer)&gGemTheme, (u8*)"slider.knob");
    i32 kw = k != (theme_slice*)0 ? (i32)k.sw : (i32)16;
    i32 sx = d((i32)20);
    i32 sw = d((i32)300);
    i32 px = sx + kw / (i32)2 + (sw - kw) * (i32)3 / (i32)4;
    press(px, d((i32)142));
    Stdio.printf("  (knob %d wide; pressed at %d; value %d)\n", kw, px, sl.nativeValue());
    ck((u8*)"a press on the slider sets the value under it", sl.nativeValue() >= (i32)74 && sl.nativeValue() <= (i32)76);
    UXImage* f = shot();
    // where the knob moved to: the columns of the slider's row that changed, right of its old place
    i32 lo = (i32)-1;
    i32 hi = (i32)-1;
    for (i32 x = sx + kw; x < sx + sw; x = x + (i32)1)
        {
        if (diff(e, f, x, d((i32)130), (i32)1, d((i32)24)) > (i32)0)
            {
            if (lo < (i32)0)
                {
                lo = x;
                }
            hi = x;
            }
        }
    i32 mid = (lo + hi) / (i32)2;
    Stdio.printf("  (GEM's knob now spans %d..%d, centre %d)\n", lo, hi, mid);
    ck((u8*)"...and GEM draws the knob there", lo >= (i32)0 && mid >= px - (i32)2 && mid <= px + (i32)2);
    ck((u8*)"none of the toolkit's drawRects ran", gToolkitDraws == (i32)0);

    // the scroll view's bar: GEM's G_SCROLL, its thumb where the toolkit's press handling puts it
    UXScrollbar* bar = sv.vbar;
    ck((u8*)"the scroll view's bar is a G_SCROLL", typeOf(bar) == (i32)G_SCROLL);
    UXRect bf = bar.absoluteFrame();
    i32 t0 = bar.thumbY();
    sv.scrollTo((i16)(sv.maxScroll() / (i32)2));
    UXImage* g = shot();
    i32 t1 = bar.thumbY();
    i32 th = bar.thumbH();
    Stdio.printf("  (bar %d tall at %d; caps %d/%d; thumb %d tall, at %d then %d)\n", (i32)bf.h, (i32)bf.y, (i32)bar.arrowH(), (i32)bar.arrowBottomH(), th, t0, t1);
    // the rows of the bar that changed: inside the old thumb or the new one, and some of each
    i32 out = (i32)0;
    i32 inNew = (i32)0;
    for (i32 y = (i32)0; y < (i32)bf.h; y = y + (i32)1)
        {
        if (diff(f, g, (i32)bf.x, (i32)bf.y + y, (i32)bf.w, (i32)1) > (i32)0)
            {
            bool inOld = y >= t0 - (i32)1 && y <= t0 + th;
            bool inN = y >= t1 - (i32)1 && y <= t1 + th;
            if (!inOld && !inN)
                {
                out = out + (i32)1;
                }
            if (inN)
                {
                inNew = inNew + (i32)1;
                }
            }
        }
    ck((u8*)"GEM moves its thumb to where the toolkit's thumb is", out == (i32)0 && inNew > th / (i32)2);
    i32 before = sv.scrollPx();
    press((i32)bf.x + (i32)bf.w / (i32)2, (i32)bf.y + (i32)bf.h - (i32)bar.arrowBottomH() / (i32)2);
    ck((u8*)"a press on GEM's down arrow scrolls down", sv.scrollPx() > before);
    // UX_SNAP_SAVE=<file>: the last picture as a PPM, for a person to look at
    u8* save = getenv((u8*)"UX_SNAP_SAVE");
    if (save != (u8*)0)
        {
        Data* ppm = UXStr.toData((u8*)"P6\n");
        ppm.append(UXStr.toData(UXStr.fromInt(g.w)));
        ppm.appendByte((u8)32);
        ppm.append(UXStr.toData(UXStr.fromInt(g.h)));
        ppm.append(UXStr.toData((u8*)"\n255\n"));
        for (i32 i = (i32)0; i < g.w * g.h; i = i + (i32)1)
            {
            ppm.appendByte((u8)((g.px[i] >> (u32)16) & (u32)255));
            ppm.appendByte((u8)((g.px[i] >> (u32)8) & (u32)255));
            ppm.appendByte((u8)(g.px[i] & (u32)255));
            }
        UXFileIO.write(save, ppm);
        }
    }

class Delegate : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        checks();
        app.stop();
        return (i32)0;
        }
    }
void main(void)
    {
    gFails = (i32)0;
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("FAIL: no gemd\n");
        return;
        }
    UXGemDriver* drv = new UXGemDriver();
    gDriver = drv;
    UXApplication* app = new UXApplication();
    app.setDriver((UXViewDriver*)drv);
    gApp = app;
    app.setDelegate(new Delegate());
    app.run();
    Stdio.printf(gFails == (i32)0 ? "PASS: GEM draws its own check box, radio buttons, slider, popup and scroll bar, from the controls' state\n" : "FAIL: %d\n", gFails);
    }
