// demo_appkit_resize.xc — a live-resizable window: the neutral toolkit tracks the native frame.
//
// Drag the window edge: the custom view reflows to fill the new size (its drawRect is handed the
// current bounds), and the app anchors a native button to the bottom-right corner + shows the live
// size — all through the neutral windowDidResize hook.  Nothing here is AppKit-aware but the driver.
//
//   Build+run:  make appkit-resize   (macOS; drag the window frame)
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXNotificationCenter.xc"
#import "UXString.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"
#import "demo_autoquit.xc" // UX_AUTOQUIT: let a sweep run this unattended

// Fills the window: drawRect is handed the view's CURRENT bounds, so the fill follows every resize.
class Canvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, dirty.w, dirty.h), (i32)8); // grey backdrop, full size
        g.fillRect(UXGeom.make((i16)0, (i16)0, dirty.w, (i16)6), (i32)2);  // red accent spans the width
        }
    }

    u8*
    sizeStr(i32 w, i32 h)
    {
    return UXStr.append(UXStr.append(UXStr.fromInt(w), (u8*)" x "), UXStr.fromInt(h));
    }

// A decoupled observer: it is NOT the app delegate, yet it hears the resize through the notification
// centre — the whole point of a bus.  It never learns which window; it just subscribed to the name.
class ResizeWatcher : Object
    {
    i32 count;
    void init(void)
        {
        count = (i32)0;
        }
    void onResize(UXNotification* n)
        {
        count = count + (i32)1;
        Stdio.printf("  [observer] heard resize to %d x %d (notification #%d)\n",
                     (i16)n.a, (i16)n.b, (i16)count);
        }
    }

    class Ctl : Object<UXApplicationDelegate>
    {
    UXWindow* win;
    UXLabel* sizeLabel;
    UXButton* corner;
    ResizeWatcher* watcher; // held here; the centre keeps only a weak ref

    void onCorner(UXControl* c)
        {
        Stdio.printf("corner button clicked\n");
        }

    i32 applicationDidStart(UXApplication* a)
        {
        Canvas* canvas = new Canvas();
        win = new UXWindow();
        win.open((u8*)"UXKit — resize me", UXGeom.make((i16)120, (i16)120, (i16)420, (i16)300), canvas);
        a.addWindow(win);

        UXLabel* hint = new UXLabel();
        hint.setText((u8*)"Drag the window edge: the view reflows, the label ellipsizes, the button anchors.");
        canvas.addSubview(hint, UXGeom.make((i16)16, (i16)20, (i16)390, (i16)16));
        hint.setAutoresizeMask((i32)UX_FLEX_WIDTH); // width tracks the window -> truncates live

        sizeLabel = new UXLabel();
        sizeLabel.setText(sizeStr((i32)420, (i32)300));
        canvas.addSubview(sizeLabel, UXGeom.make((i16)16, (i16)44, (i16)200, (i16)16));

        corner = new UXButton();
        corner.setTitle((u8*)"Corner");
        corner.setAction(&self.onCorner);
        canvas.addSubview(corner, UXGeom.make((i16)(420 - 106), (i16)(300 - 44), (i16)90, (i16)28));
        corner.setAutoresizeMask((i32)UX_ANCHOR_RIGHT | (i32)UX_ANCHOR_BOTTOM); // stays bottom-right, live

        // A separate object subscribes to the resize notification — no delegate wiring, no window ref.
        watcher = new ResizeWatcher();
        UXNotificationCenter.shared().addObserver((Object*)watcher, &watcher.onResize,
                                                  UXWindowDidResizeNotification, (Object*)0);

        win.displayAll();
        Stdio.printf("resize demo up — drag the window frame to resize\n");
        return (i32)0;
        }

    // The user resized the window.  The button re-anchors and the label ellipsizes LIVE via native
    // autoresizing (springs & struts) — no work here.  This just updates the size readout, which is
    // app data, not layout; it lands when the drag ends.
    void windowDidResize(UXApplication* a, UXWindow* w, i32 width, i32 height)
        {
        sizeLabel.setText(sizeStr(width, height));
        Stdio.printf("resized to %d x %d\n", (i16)width, (i16)height);
        }
    } void main(void)
    {
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true);
    Ctl* c = new Ctl();
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    app.setDelegate(c);
    uxAutoQuit();
    app.run();
    }
