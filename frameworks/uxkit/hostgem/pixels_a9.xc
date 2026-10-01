// pixels_a9.xc — drawPixels on the GEM backend (native arm64 on host gemd), checked as pixels.
//
// The same sheet and the same checks as mac-pixels, win32-pixels and the rest: the right way up, the
// right region, scaled, alpha honoured, both byte layouts, and a view's drawing kept inside its frame.
// The last view to draw reads the window's own surface back (vro_cpyfm, surface -> memory) -- the
// surface gemd composites -- and writes the verdict to the outcome file; run_pixels.sh asserts it.
#import <Stdio.xc>
#import "UXGemDriver.xc"
#import "UXBoot.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXImage.xc"
#import "UXString.xc"

pointer fopen(u8* path, u8* mode);
i32 fputs(u8* s, pointer f);
i32 fclose(pointer f);
void mark(u8* s)
    {
    pointer f = fopen((u8*)"/tmp/hostgem_ev_result.txt", (u8*)"a");
    if (f != (pointer)0)
        {
        fputs(s, f);
        fputs((u8*)"\n", f);
        fclose(f);
        }
    }

u8 gSheet[32]; // 4x2 RGBA:  R R G G  /  B B Y Y
void put(i32 i, i32 r, i32 g, i32 b)
    {
    gSheet[i * (i32)4] = (u8)r;
    gSheet[i * (i32)4 + (i32)1] = (u8)g;
    gSheet[i * (i32)4 + (i32)2] = (u8)b;
    gSheet[i * (i32)4 + (i32)3] = (u8)255;
    }
UXImage@ gImg;
UXApplication* gApp2;
UXView* gBoard;
bool gChecked;

// The board's surface, read back: 160x80 words of 0xRRGGBBAA.
u32 gBack[12800];
i32 gFails = 0;
void near(u8* what, i32 x, i32 y, i32 r, i32 g, i32 b)
    {
    u32 c = gBack[y * (i32)160 + x];
    i32 pr = (i32)((c >> (u32)24) & (u32)255);
    i32 pg = (i32)((c >> (u32)16) & (u32)255);
    i32 pb = (i32)((c >> (u32)8) & (u32)255);
    i32 dr = pr > r ? pr - r : r - pr;
    i32 dg = pg > g ? pg - g : g - pg;
    i32 db = pb > b ? pb - b : b - pb;
    bool ok = dr <= (i32)3 && dg <= (i32)3 && db <= (i32)3;
    Stdio.printf("  %s %s (%d,%d,%d)\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what, pr, pg, pb);
    if (!ok)
        {
        gFails = gFails + (i32)1;
        mark(UXStr.append((u8*)"MISS ", what));
        }
    }

// A view that paints far past its own frame: the part outside must not reach the window.  It is the
// last view drawn, so it also reads the board back and checks it.
class Spill : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(UXGeom.make((i16)-10, (i16)-10, (i16)60, (i16)60), (i32)255, (i32)0, (i32)0);
        if (gChecked)
            {
            return;
            }
        gChecked = true;
        MFDB screen;
        screen.addr = (u32*)0;
        MFDB mem;
        mem.addr = &gBack[(i32)0];
        mem.w = (i16)160;
        mem.h = (i16)80;
        mem.stride = (i16)160;
        mem.nplanes = (i16)32;
        mem.stand = (i16)0;
        UXRect bf = gBoard.absoluteFrame();
        i16 pxy[8];
        pxy[0] = bf.x;
        pxy[1] = bf.y;
        pxy[2] = (i16)((i32)bf.x + (i32)159);
        pxy[3] = (i16)((i32)bf.y + (i32)79);
        pxy[4] = (i16)0;
        pxy[5] = (i16)0;
        pxy[6] = (i16)159;
        pxy[7] = (i16)79;
        vro_cpyfm(aes_handle(), (i32)VRO_COPY, (pointer)&pxy[0], (pointer)&screen, (pointer)&mem);
        near("top-left of the sheet is red (not upside down)", (i32)15, (i32)15, (i32)255, (i32)0, (i32)0);
        near("bottom-left is blue", (i32)15, (i32)25, (i32)0, (i32)0, (i32)255);
        near("top-right is green", (i32)45, (i32)15, (i32)0, (i32)200, (i32)0);
        near("bottom-right is yellow", (i32)45, (i32)25, (i32)255, (i32)220, (i32)0);
        near("the sub-region starts at its own left (green)", (i32)65, (i32)15, (i32)0, (i32)200, (i32)0);
        near("...and holds its bottom row (yellow)", (i32)75, (i32)25, (i32)255, (i32)220, (i32)0);
        near("alpha 128 red over white is pink", (i32)105, (i32)15, (i32)255, (i32)127, (i32)127);
        near("a UXImage's left pixel is magenta", (i32)15, (i32)50, (i32)255, (i32)0, (i32)255);
        near("...and its right one cyan", (i32)45, (i32)50, (i32)0, (i32)255, (i32)255);
        near("outside every draw it is white", (i32)150, (i32)70, (i32)255, (i32)255, (i32)255);
        near("a view paints inside its frame", (i32)140, (i32)62, (i32)255, (i32)0, (i32)0);
        near("...and NOT past it (its drawing is clipped to its frame)", (i32)130, (i32)50, (i32)255, (i32)255, (i32)255);
        mark(gFails == (i32)0 ? (u8*)"PIXELS OK" : (u8*)"PIXELS FAIL");
        }
    }

class Board : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)255, (i32)255, (i32)255);
        g.drawPixels(&gSheet[(i32)0], (i32)4, (i32)2, (i32)UXPIX_RGBA, UXGeom.make((i16)0, (i16)0, (i16)4, (i16)2),
                     UXGeom.make((i16)10, (i16)10, (i16)40, (i16)20), (i32)255);
        g.drawPixels(&gSheet[(i32)0], (i32)4, (i32)2, (i32)UXPIX_RGBA, UXGeom.make((i16)2, (i16)0, (i16)2, (i16)2),
                     UXGeom.make((i16)60, (i16)10, (i16)20, (i16)20), (i32)255);
        g.drawPixels(&gSheet[(i32)0], (i32)4, (i32)2, (i32)UXPIX_RGBA, UXGeom.make((i16)0, (i16)0, (i16)4, (i16)2),
                     UXGeom.make((i16)100, (i16)10, (i16)40, (i16)20), (i32)128);
        gImg.drawIn(g, UXGeom.make((i16)0, (i16)0, (i16)2, (i16)1), UXGeom.make((i16)10, (i16)40, (i16)40, (i16)20), (i32)255);
        }
    }

class Delegate : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* a)
        {
        gApp2 = a;
        Board* board = new Board();
        gBoard = board;
        UXWindow* win = new UXWindow();
        win.open((u8*)"Pixels", UXGeom.make((i16)120, (i16)90, (i16)160, (i16)80), board);
        a.addWindow(win);
        board.addSubview(new Spill(), UXGeom.make((i16)135, (i16)55, (i16)15, (i16)15));
        win.tree.finalise();
        win.displayAll();
        pointer sf = fopen((u8*)"/tmp/hostgem_script.txt", (u8*)"w");
        if (sf != (pointer)0)
            {
            fputs((u8*)"DELAY 800\n", sf); // the harness only waits; the verdict is the client's
            fclose(sf);
            }
        return (i32)0;
        }
    }

void main(void)
    {
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    put((i32)0, (i32)255, (i32)0, (i32)0);
    put((i32)1, (i32)255, (i32)0, (i32)0);
    put((i32)2, (i32)0, (i32)200, (i32)0);
    put((i32)3, (i32)0, (i32)200, (i32)0);
    put((i32)4, (i32)0, (i32)0, (i32)255);
    put((i32)5, (i32)0, (i32)0, (i32)255);
    put((i32)6, (i32)255, (i32)220, (i32)0);
    put((i32)7, (i32)255, (i32)220, (i32)0);
    gImg = UXImage.make((i32)2, (i32)1);
    gImg.setPixelRaw((i32)0, (i32)0, (u32)$FFFF00FF);
    gImg.setPixelRaw((i32)1, (i32)0, (u32)$FF00FFFF);
    gDriver = new UXGemDriver();
    UXApplication* app = new UXApplication();
    app.setDelegate(new Delegate());
    app.run();
    }
