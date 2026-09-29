// test_mac_dash.xc — the DASH rendered for real on AppKit and read back as pixels.
//
// The seam can stroke a path natively but could not break the line, and a map's border IS a dash: the
// held sectors are outlined with a crawling [19.2, 10.56] at a phase that is a different number every
// frame.  Two things about that are not a matter of taste and cannot be settled by reading the docs:
//
//   THE PHASE RESTARTS AT EVERY SUBPATH.  A move starts a fresh run.  This draws TWO subpaths in ONE
//   stroke call — the same call, the same run, the same phase — and compares them sample for sample.
//   The rules differ exactly on this picture: subpath B is 85 px long and the run is 16 px, so 85 % 16
//   = 5, and a dasher that carried the phase across the move would start B five pixels into its run
//   while a dasher that restarted would reproduce A exactly.  The two rules disagree at every sample
//   below, so the check cannot pass by accident.
//
//   AND A PATTERN SHORTER THAN THE WIDTH.  A 2/2 run at a 6 px width is the case where a dasher may
//   quietly stop dashing (or fill the gaps back in), so an [8,8] row at a 6 px width is drawn beside
//   it and both are printed as run lengths — the measurement, not an opinion about it.
//
// Headless and deterministic, like test_mac_alpha: force one paint, read pixels back.  No window.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXShapePath.xc"
#import "UXPainter.xc"

i32 ux_ak_pixel(i32 handle, i32 x, i32 y); // shim: readback from the last force-painted bitmap
i32 ux_ak_dump_ppm(u8* path);

#define DASH_Y0 30
#define DASH_Y1 60
#define DASH_YP 90
#define DASH_YF 120
#define DASH_X0 10
#define DASH_X1 95

class DashBoard : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)255, (i32)255, (i32)255);
        i32 pat[2];
        pat[0] = (i32)8;
        pat[1] = (i32)8;
        // TWO subpaths in ONE call: the phase is the seam's to restart, not the caller's to fake by
        // splitting the path up.
        UXShapePath* two = new UXShapePath();
        two.moveTo((i16)DASH_X0, (i16)DASH_Y0);
        two.lineTo((i16)DASH_X1, (i16)DASH_Y0);
        two.moveTo((i16)DASH_X0, (i16)DASH_Y1);
        two.lineTo((i16)DASH_X1, (i16)DASH_Y1);
        two.setDash(&pat[0], (i32)2, (i32)0);
        UXPainter.strokePath(g, two, (i16)6, UXPainter.rgb((i32)0, (i32)0, (i32)0));
        // The same run at a phase of -4: the whole rhythm must shift by four pixels, which is what the
        // client's crawl does every frame.
        UXShapePath* ph = new UXShapePath();
        ph.moveTo((i16)DASH_X0, (i16)DASH_YP);
        ph.lineTo((i16)DASH_X1, (i16)DASH_YP);
        ph.setDash(&pat[0], (i32)2, (i32)-4);
        UXPainter.strokePath(g, ph, (i16)6, UXPainter.rgb((i32)0, (i32)0, (i32)0));
        // A run shorter than the stroke is wide.
        i32 tiny[2];
        tiny[0] = (i32)2;
        tiny[1] = (i32)2;
        UXShapePath* fine = new UXShapePath();
        fine.moveTo((i16)DASH_X0, (i16)DASH_YF);
        fine.lineTo((i16)DASH_X1, (i16)DASH_YF);
        fine.setDash(&tiny[0], (i32)2, (i32)0);
        UXPainter.strokePath(g, fine, (i16)6, UXPainter.rgb((i32)0, (i32)0, (i32)0));
        }
    }

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }
void checkTrue(u8* what, bool cond)
    {
    if (cond)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }
// Is the pixel at (x,y) ink?  Mid-line and mid-run, so it is a decision and not an antialiased edge.
bool inkAt(i32 x, i32 y)
    {
    i32 px = ux_ak_pixel((i32)1, x, y);
    i32 lum = (((px >> (i32)16) & (i32)255) * (i32)30 + ((px >> (i32)8) & (i32)255) * (i32)59
               + (px & (i32)255) * (i32)11) / (i32)100;
    return lum < (i32)128;
    }
// The run lengths along a row, printed so the short-pattern question has an ANSWER rather than an
// impression: "o5 f6 o7" is five ink pixels, six clear, seven ink.
void printRuns(i32 y)
    {
    i32 on = (i32)0;
    i32 run = (i32)0;
    Stdio.printf("  runs y=%d:", y);
    for (i32 x = DASH_X0; x <= DASH_X1; x = x + (i32)1)
        {
        i32 s = inkAt(x, y) ? (i32)1 : (i32)0;
        if (s != on && run > (i32)0)
            {
            Stdio.printf(" %c%d", on == (i32)1 ? 'o' : 'f', run);
            run = (i32)0;
            }
        on = s;
        run = run + (i32)1;
        }
    Stdio.printf(" %c%d\n", on == (i32)1 ? 'o' : 'f', run);
    }
// How many on-runs a row has — the shape of the dash, without caring where it starts.
i32 onRuns(i32 y)
    {
    i32 count = (i32)0;
    bool was = false;
    for (i32 x = DASH_X0; x <= DASH_X1; x = x + (i32)1)
        {
        bool s = inkAt(x, y);
        if (s && !was)
            {
            count = count + (i32)1;
            }
        was = s;
        }
    return count;
    }
// Does this row agree with `other` at every pixel?  Two subpaths drawn with one run must be identical
// if the phase restarts at the move, and can only agree by luck if it carries on.
i32 diffs(i32 ya, i32 yb)
    {
    i32 d = (i32)0;
    for (i32 x = DASH_X0; x <= DASH_X1; x = x + (i32)1)
        {
        if (inkAt(x, ya) != inkAt(x, yb))
            {
            d = d + (i32)1;
            }
        }
    return d;
    }

void main(void)
    {
    gFails = (i32)0;
    gDriver = new UXAppKitDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        return;
        }
    UXWindow* win = new UXWindow();
    DashBoard* board = new DashBoard();
    win.open((u8*)"Dash", UXGeom.make((i16)80, (i16)80, (i16)240, (i16)160), board);
    win.displayAll();
    ux_ak_dump_ppm((u8*)"/tmp/ux_dash_check.ppm"); // a frame to look at, not just numbers

    printRuns((i32)DASH_Y0);
    printRuns((i32)DASH_Y1);
    printRuns((i32)DASH_YP);
    printRuns((i32)DASH_YF);

    // The run is 8 on / 8 off at 6 px wide, so a row has six on-runs over 85 px.  Ink at all first: a
    // row that was never drawn makes every comparison below vacuous.
    checkTrue("the dashed line drew ink", onRuns((i32)DASH_Y0) > (i32)1);
    checkTrue("...and is broken, not solid", !inkAt((i32)22, (i32)DASH_Y0));
    checkTrue("...with ink where the run says ink", inkAt((i32)14, (i32)DASH_Y0));
    // THE RULE.  Same call, same run, same phase, two subpaths — the second must be the first.
    check("the second subpath repeats the first", diffs((i32)DASH_Y0, (i32)DASH_Y1), (i32)0);
    check("...so the phase restarted at the move", onRuns((i32)DASH_Y1), onRuns((i32)DASH_Y0));
    // THE PHASE.  Four pixels further into the run, so the whole rhythm shifts by four: the break that
    // phase 0 puts at x=18 (distance 8, the end of the first on-run) is a break at x=22 instead.
    checkTrue("at phase 0 the first on-run breaks at 18", !inkAt((i32)18, (i32)DASH_Y0));
    checkTrue("at phase -4 that pixel is still ink", inkAt((i32)18, (i32)DASH_YP));
    checkTrue("...because the break moved to 22", !inkAt((i32)22, (i32)DASH_YP));
    check("...with the same number of runs", onRuns((i32)DASH_YP), onRuns((i32)DASH_Y0));
    // THE SHORT PATTERN.  2 on / 2 off at 6 px wide: still a dash, so more runs and each one short.
    checkTrue("a 2/2 run at width 6 still draws ink", onRuns((i32)DASH_YF) > (i32)1);
    checkTrue("...and is not filled back in", onRuns((i32)DASH_YF) > onRuns((i32)DASH_Y0) + (i32)5);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the dash rests at every subpath on AppKit\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
