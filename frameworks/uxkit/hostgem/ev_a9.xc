// ev_a9.xt — the milestone-3 event-injection client (GEM backend, native arm64 on host gemd).
//
// A minimal UXKit app: one window, one "Quit" button.  It exists to prove the input path end to end
// — inject an os_event into gemd, and UXKit turns it into a fired button action.  After layout it
// prints the button's ABSOLUTE (screen) rect as `CLICK_TARGET <cx> <cy>` so the harness knows
// exactly where to click (no theme-metric guessing); the harness injects a click there, gemd
// routes it to this client, UXKit hit-tests it (objc_find), and onQuit runs -> `EVENT_ACTION_FIRED`
// + app.stop().  If the marker prints, a synthetic event drove a real action.  headless-verifiable.
#import <Stdio.xt>
#import "UXGemDriver.xt"
#import "UXBoot.xt"
#import "UXApplication.xt"
#import "UXWindow.xt"
#import "UXView.xt"
#import "UXControl.xt"
#import "UXGeometry.xt"
#import "UXGraphics.xt"
#import "UXEvent.xt"
#import "UXString.xt"

// libc file I/O (non-variadic -> safe under xtc's arm64 arg-passing): the client writes its button's
// screen centre to a file the harness polls, so the injector (in the gemd process) clicks the exact
// pixel.  A plain file, not stdout, because stdout is block-buffered and the harness must read it live.
pointer fopen(u8 @path, u8 @mode);
i32 fputs(u8 @s, pointer f);
i32 fclose(pointer f);

// A plain backdrop so the button sits on a drawn window.
class EVCanvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics @g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, dirty.w, dirty.h), (i32)8);
        }
    }

    class EventProbe : Object<UXApplicationDelegate>
    {
    UXApplication @app;
    UXWindow @win;
    UXButton @quit;

    void onQuit(UXControl @c)
        {
        Stdio.printf("EVENT_ACTION_FIRED\n"); // the injected click reached the button's action
        // Also record it to a file: stdout is block-buffered and the harness may signal us before a
        // clean exit flushes it, so the file is the reliable witness that the action ran.
        pointer rf = fopen((u8 @) "/tmp/hostgem_ev_result.txt", (u8 @) "w");
        if (rf != (pointer)0)
            {
            fputs((u8 @) "EVENT_ACTION_FIRED\n", rf);
            fclose(rf);
            }
        app.stop();
        }

    i32 applicationDidStart(UXApplication @a)
        {
        app = a;
        EVCanvas @canvas = new EVCanvas();
        win = new UXWindow();
        win.open((u8 @) "UXKit Event Probe", UXGeom.make((i16)120, (i16)90, (i16)300, (i16)160), canvas);
        a.addWindow(win);
        quit = new UXButton();
        quit.setTitle((u8 @) "Quit");
        quit.setAction(&self.onQuit);
        canvas.addSubview(quit, UXGeom.make((i16)100, (i16)70, (i16)100, (i16)32));
        win.tree.finalise();
        win.displayAll();
        // Report the button's WINDOW-LOCAL centre + the window handle.  absoluteFrame is local (the
        // tree root sits at 0,0; a client never knows its screen placement — gemd owns it), so the
        // harness converts local->screen with gemd's wind_work_origin before injecting.  Format:
        // "<handle> <local_cx> <local_cy>".
        UXRect f = quit.absoluteFrame();
        i32 cx = (i32)f.x + (i32)f.w / (i32)2;
        i32 cy = (i32)f.y + (i32)f.h / (i32)2;
        Stdio.printf("CLICK_TARGET handle=%ld local=%ld,%ld\n", win.handle, cx, cy);
        u8 @line = UXStr.append(UXStr.append(UXStr.append(UXStr.append(UXStr.append(
                                                                           UXStr.fromInt(win.handle), (u8 @) " "),
                                                                       UXStr.fromInt(cx)),
                                                          (u8 @) " "),
                                             UXStr.fromInt(cy)),
                                (u8 @) "\n");
        pointer cf = fopen((u8 @) "/tmp/hostgem_click.txt", (u8 @) "w");
        if (cf != (pointer)0)
            {
            fputs(line, cf);
            fclose(cf);
            }
        return (i32)0;
        }
    }

    void
    main(void)
    {
    if (!UXBoot.ensureWindowServer())
        {
        Stdio.printf("no gemd\n");
        return;
        }
    gDriver = new UXGemDriver();
    EventProbe @probe = new EventProbe();
    UXApplication @app = new UXApplication();
    app.setDelegate(probe);
    app.run();
    Stdio.printf("event probe exited\n");
    }
