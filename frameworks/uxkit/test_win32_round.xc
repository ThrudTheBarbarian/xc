// test_win32_round.xc — a rounded panel on Win32, whose scroll view is a native WS_VSCROLL child.
//
// A 16px-rounded scroll view with a dark edge, its document solid red and tall enough for the bar.
// The child's window region must be the rounded shape (a point just inside the frame's corner is
// outside it, the middle inside), the edge is framed in the border colour, and the content is drawn
// inside.  Read from the child's own window DC.  Build+run: sh run_win32_round.sh (under Wine).
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"

pointer FindWindowExA(pointer parent, pointer after, pointer cls, pointer title);
pointer CreateRectRgn(i32 x1, i32 y1, i32 x2, i32 y2);

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

i32 gFails = 0;
void ck(bool ok, u8* what, u32 v)
    {
    Stdio.printf("  %s %s (%08x)\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what, v);
    if (!ok)
        {
        gFails = gFails + (i32)1;
        }
    }
// COLORREF 0x00BBGGRR
bool isRed(u32 c) { return (c & (u32)255) > (u32)200 && ((c >> (u32)8) & (u32)255) < (u32)70; }
bool isEdge(u32 c) { return (c & (u32)255) < (u32)90 && ((c >> (u32)8) & (u32)255) < (u32)90 && ((c >> (u32)16) & (u32)255) < (u32)90; }

class Delegate : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        RoundBoard* board = new RoundBoard();
        UXWindow* win = new UXWindow();
        win.open((u8*)"Round", UXGeom.make((i16)40, (i16)40, (i16)200, (i16)140), board);
        UXScrollView* sv = new UXScrollView();
        sv.setCornerRadius((i32)16);
        sv.setBorderRGB((i32)60, (i32)60, (i32)60);
        board.addSubview(sv, UXGeom.make((i16)20, (i16)20, (i16)140, (i16)90));
        sv.document().addSubview(new RoundDoc(), UXGeom.make((i16)0, (i16)0, (i16)200, (i16)400));
        sv.setDocumentHeight((i32)400);
        app.addWindow(win);
        win.displayAll();
        pointer hw = gW32Hwnds[win.handle];
        UpdateWindow(hw);
        pointer child = FindWindowExA(hw, (pointer)0, (pointer) "UXScroll32", (pointer)0);
        ck(child != (pointer)0, "the scroll view is a native child", (u32)0);
        if (child != (pointer)0)
            {
            UpdateWindow(child);
            pointer rgn = CreateRectRgn((i32)0, (i32)0, (i32)1, (i32)1);
            i32 kind = GetWindowRgn(child, rgn);
            ck(kind > (i32)1, "the child has a window region", (u32)kind);
            ck(PtInRegion(rgn, (i32)2, (i32)2) == (i32)0, "a point just inside the frame's corner is cut", (u32)0);
            ck(PtInRegion(rgn, (i32)70, (i32)45) != (i32)0, "the middle is kept", (u32)0);
            DeleteObject(rgn);
            pointer wdc = GetWindowDC(child);
            u32 edge = GetPixel(wdc, (i32)70, (i32)0);
            ck(isEdge(edge), "the edge is framed in the border colour along the top", edge);
            u32 left = GetPixel(wdc, (i32)0, (i32)45);
            ck(isEdge(left), "...and down the left", left);
            u32 inner = GetPixel(wdc, (i32)50, (i32)45);
            ck(isRed(inner), "the content is drawn inside", inner);
            ReleaseDC(child, wdc);
            }
        if (gFails == (i32)0)
            {
            Stdio.printf("PASS: a rounded panel on Win32 -- region rounded, edge framed, content inside\n");
            }
        else
            {
            Stdio.printf("FAIL: %d\n", gFails);
            }
        app.stop();
        return (i32)0;
        }
    }

void main(void)
    {
    gDriver = new UXWin32Driver();
    UXApplication* app = new UXApplication();
    app.setDelegate(new Delegate());
    app.run();
    }
