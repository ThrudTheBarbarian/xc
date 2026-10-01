// evinput_a9.xc — hover, the secondary button and the wheel on the GEM backend (native arm64 on host
// gemd), the same three the other backends deliver.  One window whose canvas records what reaches it;
// the client writes an injection script (host_gemd `script` mode plays it): a click to focus the
// window (gemd sends motion only to the focused one), a hover, a right click, a wheel notch, then Quit.
// Each hook appends an outcome marker, which run_input.sh asserts.
#import <Stdio.xc>
#import "UXGemDriver.xc"
#import "UXBoot.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"
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
u8* cat(u8* a, u8* b) { return UXStr.append(a, b); }
u8* i2s(i32 n) { return UXStr.fromInt(n); }
// "<VERB> <handle> <x> <y>\n"
u8* line3(u8* verb, i32 h, i32 x, i32 y)
    {
    return cat(cat(cat(cat(cat(cat(verb, i2s(h)), (u8*)" "), i2s(x)), (u8*)" "), i2s(y)), (u8*)"\n");
    }

bool gMoved;
bool gRight;
bool gWheel;
class Probe : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)255, (i32)255, (i32)255);
        }
    void mouseMoved(UXEvent* e)
        {
        if (!gMoved && (i32)e.x >= (i32)150 && (i32)e.x < (i32)170)
            {
            gMoved = true;
            mark((u8*)"MOVED");
            }
        }
    void rightMouseDown(UXEvent* e)
        {
        if (!gRight)
            {
            gRight = true;
            mark(cat(cat(cat((u8*)"RIGHT ", i2s((i32)e.x)), (u8*)","), i2s((i32)e.y)));
            }
        }
    void scrollWheel(UXEvent* e)
        {
        if (!gWheel)
            {
            gWheel = true;
            mark(cat(cat(cat((u8*)"WHEEL ", i2s(e.a)), (u8*)" "), i2s(e.b)));
            }
        }
    }

class Delegate : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    void onQuit(UXControl* c)
        {
        mark((u8*)"QUIT");
        app.stop();
        }
    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        Probe* probe = new Probe();
        UXWindow* win = new UXWindow();
        win.open((u8*)"UXKit Input", UXGeom.make((i16)120, (i16)90, (i16)320, (i16)200), probe);
        a.addWindow(win);
        UXButton* quit = new UXButton();
        quit.setTitle((u8*)"Quit");
        quit.setAction(&self.onQuit);
        probe.addSubview(quit, UXGeom.make((i16)200, (i16)150, (i16)90, (i16)28));
        win.tree.finalise();
        win.displayAll();

        i32 h = win.handle;
        pointer sf = fopen((u8*)"/tmp/hostgem_script.txt", (u8*)"w");
        if (sf != (pointer)0)
            {
            fputs(line3((u8*)"CLICK ", h, (i32)30, (i32)30), sf);   // focus the window
            fputs((u8*)"DELAY 200\n", sf);
            fputs(line3((u8*)"MOVE ", h, (i32)160, (i32)40), sf);   // hover -> MOVED
            fputs((u8*)"DELAY 200\n", sf);
            fputs(line3((u8*)"RCLICK ", h, (i32)70, (i32)80), sf);  // -> RIGHT 70,80
            fputs((u8*)"DELAY 200\n", sf);
            fputs(cat(cat(cat(cat(cat((u8*)"WHEEL ", i2s(h)), (u8*)" 60 60 "), i2s((i32)-1)), (u8*)""), (u8*)"\n"), sf); // one notch down
            fputs((u8*)"DELAY 300\n", sf);
            fputs(line3((u8*)"CLICK ", h, (i32)245, (i32)164), sf); // Quit
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
    gDriver = new UXGemDriver();
    UXApplication* app = new UXApplication();
    app.setDelegate(new Delegate());
    app.run();
    }
