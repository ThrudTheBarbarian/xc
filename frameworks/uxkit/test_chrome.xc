// test_chrome.xc — chrome is a MODEL the AES renders (§11).
//
// The point: every chrome field goes through the STANDARD call, wind_set — including
// the classic hi/lo pointer split, so an m68k app binds to it directly.  Before this,
// wind_set implemented exactly ONE field (WF_CURRXYWH) and silently ignored WF_NAME —
// so a classic app's window title did nothing at all, and nobody noticed because
// wind_set_name() gave our own tree a working path around the hole.
#import <Stdio.xc>
#import <GEM>
#import "UXApplication.xc"
#import "UXGemDriver.xc"
#import "UXBoot.xc"

i32 wind_get_str(i32 h, i32 field, pointer a, pointer b);

class Controller : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    void init(void)
        {
        }

    // read a string field back out of the AES's OWN copy (hi/lo, as classic GEM does)
    u8* readField(i32 h, i32 field)
        {
        i32 hi = (i32)0;
        i32 lo = (i32)0;
        if (wind_get_str(h, field, &hi, &lo) == (i32)0)
            {
            return "<none>";
            }
        u32 p = (((u32)hi & (u32)$FFFF) << (u32)16) | ((u32)lo & (u32)$FFFF);
        return (u8*)p;
        }

    i32 applicationDidStart(UXApplication* a)
        {
        i32 sw = a.screenWidth();
        i32 sh = a.screenHeight();
        UXView* content = new UXView();
        win = new UXWindow();
        a.addWindow(win);
        win.open("Rocks", UXGeom.make((i16)2, (i16)2, (i16)(sw - (i32)4), (i16)(sh - (i32)4)), content);

        // The window was opened via UXWindow.setTitle -> wind_set(WF_NAME, hi, lo).
        Stdio.printf("1. WF_NAME  after open: \"%s\"\n", self.readField(win.handle, (i32)WF_NAME));

        win.setSubtitle("/System/OS/Apps/Desktop/desktop.rsc");
        win.setInfo("11 objects   tree 0 of 1");
        win.setIcon("alert.note");
        win.setModified(true);

        Stdio.printf("2. WF_SUBTITLE:         \"%s\"\n", self.readField(win.handle, (i32)WF_SUBTITLE));
        Stdio.printf("3. WF_INFO:             \"%s\"\n", self.readField(win.handle, (i32)WF_INFO));
        Stdio.printf("4. WF_ICON:             \"%s\"\n", self.readField(win.handle, (i32)WF_ICON));

        // ---- and the RAW classic call, exactly as an m68k app would make it ------
        u8* s = "Untitled";
        u32 p = (u32)s;
        wind_set(win.handle, (i32)WF_NAME,
                 (i32)((p >> (u32)16) & (u32)$FFFF), (i32)(p & (u32)$FFFF), (i32)0, (i32)0);
        u8* got = self.readField(win.handle, (i32)WF_NAME);
        Stdio.printf("5. raw wind_set(WF_NAME, hi, lo) -> \"%s\"\n", got);

        bool ok = got[0] == (u8)85 && got[1] == (u8)110; // "Un..."
        u8* sub = self.readField(win.handle, (i32)WF_SUBTITLE);
        u8* inf = self.readField(win.handle, (i32)WF_INFO);
        ok = ok && sub[0] == (u8)47 && inf[0] == (u8)49; // '/' and '1'

        if (ok)
            {
            Stdio.printf("PASS: every chrome field goes through wind_set, with the classic\n");
            Stdio.printf("      hi/lo pointer split.  The AES keeps its OWN copy — which is\n");
            Stdio.printf("      what lets gemd repaint a WEDGED app's title bar.\n");
            }
        else
            {
            Stdio.printf("FAIL\n");
            }
        a.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    // qemu has no SD card, so init started no gemd.  TEST-ONLY (UXBoot.xc).
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }

    gDriver = new UXGemDriver(); // select the GEM backend (UXApplication is neutral)
    UXApplication* app = new UXApplication();
    Controller* c = new Controller();
    app.setDelegate(c);
    app.run();
    }
