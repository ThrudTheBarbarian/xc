// test_mac_weight.xc — a family at a NUMERIC WEIGHT rendered for real on AppKit, read back as pixels.
//
// The seam could already name a family (drawTextFont, with a bool `bold`) and could already carry a
// colour and an alpha (drawTextRGBA), but a map's labels need all four at once and the weight is 600 —
// semibold, which a bool cannot say.  This draws the same string three times in one monospace family
// and reads the ink back: the 600 face has to ink HEAVIER than the 400 at the same size, and a label's
// alpha has to lighten the glyphs rather than be dropped.  Without the change both weights resolve to
// the regular face (or to bold), and the ink counts come out equal, which is what the checks reject.
//
// It also measures the two TEXT METRICS the same way, because the map's labels need them and a metric
// is only a promise until a pixel agrees with it: the WIDTH AT A WEIGHT (the seam could draw at 600
// and measure only at bold) is compared with the ink the same string actually lays down, and the
// ASCENT (the distance from the top of the line to the baseline — what a caller holding a canvas
// baseline needs) is checked against where the glyphs stop on the pixel grid.
//
// Headless and deterministic, like test_mac_alpha: force one paint, read pixels back.  No window.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXPainter.xc"

i32 ux_ak_pixel(i32 handle, i32 x, i32 y); // shim: readback from the last force-painted bitmap
i32 ux_ak_dump_ppm(u8* path);

class FaceBoard : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)255, (i32)255, (i32)255);
        // One family, one size, three rows: regular, semibold, and regular-at-alpha.  The family is
        // spelled the way the map's ink spells it (a fallback list is the client's to resolve, not this
        // gate's), and the two weights are 200 apart so no hinting accident can close the gap.
        g.drawTextFontRGBA((u8*)"MMMMM", (i16)10, (i16)40, (u8*)"Menlo", (i32)24,
                           (i32)UXWEIGHT_NORMAL, false, (i32)0, (i32)0, (i32)0, (i32)255);
        g.drawTextFontRGBA((u8*)"MMMMM", (i16)10, (i16)90, (u8*)"Menlo", (i32)24,
                           (i32)UXWEIGHT_SEMIBOLD, false, (i32)0, (i32)0, (i32)0, (i32)255);
        g.drawTextFontRGBA((u8*)"MMMMM", (i16)10, (i16)140, (u8*)"Menlo", (i32)24,
                           (i32)UXWEIGHT_NORMAL, false, (i32)0, (i32)0, (i32)0, (i32)128);
        // Row 4: a PROPORTIONAL face at 600, for the weighted measure to be checked against (a
        // monospace face measures the same at every weight, which would prove nothing).
        g.drawTextFontRGBA((u8*)"Hamburgefonstiv", (i16)10, (i16)190, (u8*)"Helvetica", (i32)24,
                           (i32)UXWEIGHT_SEMIBOLD, false, (i32)0, (i32)0, (i32)0, (i32)255);
        // Row 5: cap-height glyphs and no descender, so the last inked row IS the baseline.
        g.drawTextFontRGBA((u8*)"HHHH", (i16)10, (i16)250, (u8*)"Menlo", (i32)24,
                           (i32)UXWEIGHT_NORMAL, false, (i32)0, (i32)0, (i32)0, (i32)255);
        }
    }

// The ink box of a region: min/max inked column and row, and how many pixels are inked at all.
i32 gMinX;
i32 gMaxX;
i32 gMinY;
i32 gMaxY;
i32 gInked;
void inkBox(i32 x0, i32 x1, i32 y0, i32 y1)
    {
    gMinX = (i32)0 - (i32)1;
    gMaxX = (i32)0 - (i32)1;
    gMinY = (i32)0 - (i32)1;
    gMaxY = (i32)0 - (i32)1;
    gInked = (i32)0;
    for (i32 y = y0; y <= y1; y = y + (i32)1)
        {
        for (i32 x = x0; x <= x1; x = x + (i32)1)
            {
            i32 px = ux_ak_pixel((i32)1, x, y);
            i32 lum = (rr(px) * (i32)30 + gg(px) * (i32)59 + bb(px) * (i32)11) / (i32)100;
            if (lum < (i32)200)
                {
                if (gMinX < (i32)0 || x < gMinX)
                    {
                    gMinX = x;
                    }
                if (gMaxX < (i32)0 || x > gMaxX)
                    {
                    gMaxX = x;
                    }
                if (gMinY < (i32)0 || y < gMinY)
                    {
                    gMinY = y;
                    }
                if (gMaxY < (i32)0 || y > gMaxY)
                    {
                    gMaxY = y;
                    }
                gInked = gInked + (i32)1;
                }
            }
        }
    }

i32 gFails;
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
i32 rr(i32 px)
    {
    return (px >> (i32)16) & (i32)255;
    }
i32 gg(i32 px)
    {
    return (px >> (i32)8) & (i32)255;
    }
i32 bb(i32 px)
    {
    return px & (i32)255;
    }
// Total ink over a text row: sum of (255 - luminance) across the box, so a heavier face — which covers
// more of the same glyphs — scores higher even where both faces reach the same dark value.
i32 rowInk(i32 y0, i32 y1)
    {
    i32 sum = (i32)0;
    for (i32 y = y0; y <= y1; y = y + (i32)1)
        {
        for (i32 x = (i32)8; x <= (i32)180; x = x + (i32)1)
            {
            i32 px = ux_ak_pixel((i32)1, x, y);
            i32 lum = (rr(px) * (i32)30 + gg(px) * (i32)59 + bb(px) * (i32)11) / (i32)100;
            sum = sum + ((i32)255 - lum);
            }
        }
    return sum;
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
    FaceBoard* board = new FaceBoard();
    win.open((u8*)"Weight", UXGeom.make((i16)80, (i16)80, (i16)320, (i16)300), board);
    win.displayAll();
    ux_ak_dump_ppm((u8*)"/tmp/ux_weight_check.ppm"); // a frame to look at, not just numbers

    // Boxes cover each row's glyphs with slack; the rows are 50px apart so they cannot overlap.
    i32 regular = rowInk((i32)36, (i32)66);
    i32 semibold = rowInk((i32)86, (i32)116);
    i32 faded = rowInk((i32)136, (i32)166);
    Stdio.printf("ink regular=%d semibold=%d faded@128=%d\n", regular, semibold, faded);

    // Some ink has to land at all, or the two comparisons below are 0 > 0 and prove nothing.
    checkTrue("the regular row drew something", regular > (i32)200);
    // The point: 600 is a heavier face than 400 at the same family and size.
    checkTrue("the semibold face inks heavier than the regular", semibold > regular + (i32)200);
    // And a label's alpha lightens the glyph rather than being dropped on the floor.
    checkTrue("an alpha-128 label inks lighter than an opaque one", faded < regular);

    // THE WEIGHTED MEASURE.  Same string, same family, same size: what textWidthWeight says at 600
    // against the ink that row actually lays down, and against the plain 400 (a proportional face, so
    // the number moves with the weight).
    i32 w600 = gDriver.textWidthWeight((u8*)"Hamburgefonstiv", (u8*)"Helvetica", (i32)24,
                                       (i32)UXWEIGHT_SEMIBOLD, false);
    i32 w400 = gDriver.textWidthWeight((u8*)"Hamburgefonstiv", (u8*)"Helvetica", (i32)24,
                                       (i32)UXWEIGHT_NORMAL, false);
    inkBox((i32)8, (i32)300, (i32)186, (i32)216);
    i32 drawn = gMaxX - gMinX + (i32)1;
    Stdio.printf("measure w600=%d w400=%d  drawn=%d (x %d..%d)\n", w600, w400, drawn, gMinX, gMaxX);
    checkTrue("the weighted measure drew a row to check against", gInked > (i32)200);
    // The measure is the pen ADVANCE, so it is never narrower than the ink and cannot overshoot it by
    // more than the last glyph's side bearing (a pixel or two at this size).
    checkTrue("the weighted measure agrees with the ink the row laid down",
              w600 >= drawn && w600 - drawn <= (i32)4);
    checkTrue("a heavier weight does not measure narrower", w600 >= w400);

    // THE ASCENT.  Row 5 is cap-height glyphs with no descender, so its last inked row is the
    // baseline the seam drew at: y + textAscent.  If the ascent were short, the glyphs would sit
    // above that row; if it were long, the ink would cross it.
    i32 ascent = gDriver.textAscent((u8*)"Menlo", (i32)24, (i32)UXWEIGHT_NORMAL, false);
    inkBox((i32)8, (i32)300, (i32)246, (i32)284);
    Stdio.printf("ascent=%d  row5 ink y %d..%d  baseline=%d\n", ascent, gMinY, gMaxY, (i32)250 + ascent);
    checkTrue("the ascent is a real face metric", ascent > (i32)12 && ascent < (i32)32);
    // The face's ascender is fractional and the metric is a whole pixel, so the glyphs' feet land
    // within one pixel of the baseline the metric names.  A cap height or the em size would be five
    // or more away — that is what makes this a check and not a tautology.
    checkTrue("the glyphs sit on the baseline the ascent reports",
              gMaxY >= (i32)248 + ascent && gMaxY <= (i32)249 + ascent);
    checkTrue("and nothing is inked above the top of the line", gMinY >= (i32)250);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the seam's family+weight+colour+alpha resolve on AppKit\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
