// round_body.xc — the rounded-panel checks, shared by every backend that draws its own scroll view.
// The including file supplies roundPixel(x, y) -> 0xRRGGBB, roundRender(handle), roundEdge(handle) ->
// the edge's colour along the top (a rig that cannot rasterise a stroke answers from its record) and
// ROUND_BACKEND, and sets gDriver before calling roundBody().  Returns the number of failed checks.

class RoundBoard : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)255, (i32)255, (i32)255);
        }
    }
class RoundDoc : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)230, (i32)20, (i32)20);
        }
    }

i32 gRoundFails;
void rck(bool ok, u8* what, i32 px)
    {
    Stdio.printf("  %s %s (%06x)\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what, px);
    if (!ok)
        {
        gRoundFails = gRoundFails + (i32)1;
        }
    }
bool isWhite(i32 c) { return ((c >> (i32)16) & (i32)255) > (i32)235 && ((c >> (i32)8) & (i32)255) > (i32)235 && (c & (i32)255) > (i32)235; }
bool isRed(i32 c) { return ((c >> (i32)16) & (i32)255) > (i32)200 && ((c >> (i32)8) & (i32)255) < (i32)70; }
bool isDark(i32 c) { return ((c >> (i32)16) & (i32)255) < (i32)140 && ((c >> (i32)8) & (i32)255) < (i32)140; }

i32 roundBody(void)
    {
    gRoundFails = (i32)0;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display\n");
        return (i32)0;
        }
    UXWindow* win = new UXWindow();
    RoundBoard* board = new RoundBoard();
    win.open((u8*)"Round", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)140), board);
    UXScrollView* sv = new UXScrollView();
    sv.setCornerRadius((i32)16);
    sv.setBorderRGB((i32)60, (i32)60, (i32)60);
    board.addSubview(sv, UXGeom.make((i16)20, (i16)20, (i16)140, (i16)90));
    sv.document().addSubview(new RoundDoc(), UXGeom.make((i16)0, (i16)0, (i16)200, (i16)400));
    sv.setDocumentHeight((i32)400); // taller than the panel: the bar is shown
    win.displayAll();
    roundRender(win.handle);

    i32 corner = roundPixel((i32)22, (i32)22);
    rck(isWhite(corner), "the corner is cut: white just inside the frame's corner", corner);
    i32 edge = roundEdge(win.handle);
    rck(isDark(edge), "the edge is drawn along the top", edge);
    i32 inner = roundPixel((i32)60, (i32)60);
    rck(isRed(inner), "the content fills the inside", inner);
    i32 below = roundPixel((i32)80, (i32)112);
    rck(isWhite(below), "nothing past the panel's bottom", below);
    UXRect bf = sv.vbar.frame();
    rck((i32)bf.y >= (i32)16 && (i32)bf.y + (i32)bf.h <= (i32)90 - (i32)16, "the bar is inset between the corners", (i32)bf.y);
    if (gRoundFails == (i32)0)
        {
        Stdio.printf("PASS: a rounded panel on %s -- corner cut, edge drawn, content inside, bar inset\n", (u8*)ROUND_BACKEND);
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gRoundFails);
        }
    return gRoundFails;
    }
