// UXApplication.xc — boot, the run loop, and the top of the responder chain.
//
// A program's main() is small: make an UXApplication, give it a delegate, run().
// The loop is evnt_multi — and note the AES has ALREADY consumed menu-bar and
// window-frame clicks before we see anything, so Xtg never tries to own chrome.
#import "UXWindow.xc"
#import "UXEvent.xc"
#import "UXMenu.xc"
#import "UXNotificationCenter.xc"

protocol UXApplicationDelegate
    {
    i32 applicationDidStart(UXApplication * app);
    // The user resized a window (the native frame does the drag; the toolkit has already reflowed the
    // tree and repainted).  width/height are the new content-area size.  OPTIONAL — most apps whose
    // layout is fixed ignore it; an app that anchors or reflows its own views implements it.
    optional void windowDidResize(UXApplication * app, UXWindow * win, i32 width, i32 height);
    }

// The type of that optional method, so it can be taken as a `callback` and tested.
class UXApplication : UXResponder
    {
    UXApplicationDelegate* delegate;
    Array<UXWindow>* windows;
    weak : UXWindow* keyWindow; // the window the keyboard is talking to
    UXMenuBar* menuBar;
    bool running;
    i32 screenW;
    i32 screenH;
    Array<UXWindow>* pendingCloses; // windows a control's action asked to close (see closeWindowLater)

    void init(void)
        {
        super.init();
        delegate = (UXApplicationDelegate*)0;
        windows = new Array();
        running = false;
        screenW = (i32)0;
        screenH = (i32)0;
        menuBar = (UXMenuBar*)0;
        pendingCloses = new Array();
        }

    // Install a menu bar.  From here on GEM owns the bar: it draws it, tracks the
    // pull-down, intercepts the click inside evnt_multi, and posts MN_SELECTED.
    void setMenuBar(UXMenuBar* mb)
        {
        menuBar = mb;
        mb.install(screenW);
        }

    void setDelegate(UXApplicationDelegate* d)
        {
        delegate = d;
        }

    // Select the backend.  Source clients can assign the `gDriver` global directly; clients
    // linking libUXKit.so through `<UXKit>` cannot name that global, so they hand the driver here
    // (the driver is the neutral protocol type — this adds no GEM coupling to UXApplication).
    void setDriver(UXViewDriver* d)
        {
        gDriver = d;
        }
    i32 screenWidth(void)
        {
        return screenW;
        }
    i32 screenHeight(void)
        {
        return screenH;
        }

    // Boot GEM.  This is the ~20 lines every C GEM app copy-pastes; now it lives
    // in one place, and the app never sees it.
    //
    // NOTE: this is the SERVER path — it initialises the AES, which means the
    // process running it IS the window system (see doc/AES-SERVER.md).  That is
    // true today because aesdesk is the only GEM process, but it is not what an
    // application should do: libGEM's window list is a per-process static, so a
    // second GEM process would get a PRIVATE AES drawing to the same framebuffer.
    //
    // Once the AES server lands this becomes attach(): connect, get an ap_id, get
    // a backing surface.  Nothing else in Xtg changes — views, the responder chain,
    // the draw seam, target/action, the run loop and the .rsc nib path all sit ON
    // the AES API rather than underneath it, so the split is invisible to them.
    // The BACKEND IS INJECTED, not chosen here — so UXApplication names no GEM type and its
    // whole graph compiles for win64.  The program's bootstrap sets `gDriver` before run()
    // (UXBoot for the GEM tests/demos; `new UXWin32Driver()` for a Win32 app); boot() just
    // brings the chosen backend up.  A null driver here means nobody selected a backend.
    bool boot(void)
        {
        if (gDriver == (UXViewDriver*)0)
            {
            return false;
            }
        return gDriver.boot(&screenW, &screenH); // the driver owns its graphics + theme
        }

    void addWindow(UXWindow* w)
        {
        windows.add(w);
        w.setNextResponder(self); // window -> application
        if (keyWindow == (UXWindow*)0)
            {
            keyWindow = w;
            }
        }

    void stop(void)
        {
        running = false;
        }

    // Close ONE window: destroy its native window, drop it from the list, and quit the app only when
    // that was the last one (closing a secondary window must leave the others — and the app — running).
    void closeWindow(UXWindow* w)
        {
        i32 n = (i32)windows.count();
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            UXWindow* wi = (UXWindow* ?)windows.get((u16)i);
            if (wi != (UXWindow*)0 && wi.handle == w.handle)
                {
                windows.removeAt((u16)i);
                break;
                }
            }
        if (keyWindow == w)
            {
            keyWindow = windows.count() > (u16)0 ? (UXWindow * ?) windows.get((u16)0) : (UXWindow*)0;
            }
        w.close(); // destroy the native window (handle -> 0)
        // last window closed -> quit
        if (windows.count() == (u16)0)
            {
            self.stop();
            }
        }
    // Close a window SAFELY from inside a control's action.  A native button's click is handled inside the
    // backend's window proc (Win32 SENDs WM_COMMAND), so destroying that window there (DestroyWindow) frees
    // it mid-message and crashes.  Queue it instead; the run loop closes it once the proc has returned.
    void closeWindowLater(UXWindow* w)
        {
        if (w != (UXWindow*)0)
            {
            pendingCloses.add(w);
            }
        }
    void drainPendingCloses(void)
        {
        while (pendingCloses.count() > (u16)0)
            {
            UXWindow* w = (UXWindow* ?)pendingCloses.get((u16)0);
            pendingCloses.removeAt((u16)0);
            if (w != (UXWindow*)0 && w.isOpen())
                {
                self.closeWindow(w);
                }
            }
        }
    // interactive AppKit reads this to break [NSApp run]
    bool isRunning(void)
        {
        return running;
        }

    // Drain whatever gemd has already said, without blocking.
    //
    // Under gemd a lot of the truth is ASYNCHRONOUS. Ask for a rect and gemd clamps it;
    // report a content size and gemd takes 16px of your work area for a scrollbar. Neither
    // answer lands in your window until you run an evnt_multi, because that is where the
    // client library absorbs MSG_SIZED / MSG_MOVED / MSG_VSLID and updates its window list.
    //
    // So a client that sets something and immediately reads it back is reading its own
    // request, not gemd's answer. pump() is how you wait for the answer: one evnt_multi with
    // a short timer, which returns as soon as the messages are in.
    void pump(i32 ms)
        {
        UXEvent* ev = new UXEvent();
        gDriver.pumpMessages(ms, ev); // drains window messages, not input
        self.dispatchEvent(ev);
        }

    // The delegate's start moment, factored so BOTH loop shapes share it: the
    // neutral loop below runs it inline; a driver that owns the loop (iOS)
    // calls it from its native start callback (didFinishLaunching) — the
    // settled B+A model, run() staying one call in app code either way.
    i32 startDelegate(void)
        {
        if (delegate == (UXApplicationDelegate*)0)
            {
            return (i32)2;
            }
        i32 rc = delegate.applicationDidStart(self);
        if (rc == (i32)0)
            {
            self.displayIfNeeded();
            }
        return rc;
        }

    // The run loop.  One event; dispatch; repeat — except where the PLATFORM
    // insists on owning the loop (iOS): there run() hands the thread to the
    // driver's native loop, which never returns, and the app's life continues
    // through the driver's callbacks.  The one sanctioned loop inversion
    // (private:PLAN-UXKIT.md, the spiked decision); every other backend keeps the
    // blocking shape below, byte-identical.
    i32 run(void)
        {
        if (!self.boot())
            {
            return (i32)1;
            }
        if (delegate == (UXApplicationDelegate*)0)
            {
            return (i32)2;
            }
        gApp = self; // a modal drag loop (table select / scrollbar) repaints through it

        // running BEFORE the delegate runs, so a delegate that calls stop() during
        // start-up (a test, a one-shot tool) is honoured rather than ignored.
        running = true;
        if (gDriver.driverOwnsRunLoop())
            {
            gDriver.runLoop(); // never returns; startDelegate() fires from the driver
            return (i32)0;
            }
        i32 rc = delegate.applicationDidStart(self);
        if (rc != (i32)0)
            {
            return rc;
            }

        // One event object, reused: allocating inside the loop churns the heap.
        UXEvent* ev = new UXEvent();
        while (running)
            {
            gDriver.nextEvent((i32)0, ev); // block for the next input or window message
            self.dispatchEvent(ev);
            if (gNeedsDisplay)
                {
                self.displayIfNeeded();
                }
            self.drainPendingCloses(); // now safe: no window proc is on the stack
            }
        return (i32)0;
        }

    // One repaint per loop iteration, however many views asked for it — and each
    // window repaints only the UNION of the rects its views marked.  A window whose
    // views said nothing costs a single bool test.
    void displayIfNeeded(void)
        {
        if (!gNeedsDisplay)
            {
            return;
            }
        gNeedsDisplay = false;
        for (Object* o in windows)
            {
            UXWindow* w = (UXWindow* ?)o;
            if (w != (UXWindow*)0)
                {
                w.display();
                }
            }
        }

    // A TAP on the event stream: every event passes through dispatchEvent, so one hook here sees the
    // lot.  The event recorder is the reason it exists — a recorder cannot capture what it cannot
    // see, and the run loop is the only place the whole stream is in one piece.  The tap is called
    // BEFORE dispatch and must not consume: it is a tee, not a filter.  Replay feeds dispatchMouse /
    // dispatchKey directly, below the tap, so a replay is never itself recorded.
    void setEventTap(callback t void(UXEvent* e))
        {
        gEventTap = t;
        }

    // Dispatch one neutral event.  The driver already decoded the backend's native message,
    // so this names no GEM constant — it is the same on every host.
    void dispatchEvent(UXEvent* ev)
        {
        if (gEventTap != (callback void(UXEvent * e))0)
            {
            gEventTap(ev);
            }
        u8 k = ev.kind;
        if (k == (u8)UXEventMouseDown)
            {
            // A backend that knows WHICH window was clicked tags ev.handle (Win32: client coords can't
            // tell windows apart); one that reports screen coords (GEM) leaves it 0 and we hit-test by point.
            UXWindow* w = ev.handle != (i32)0 ? self.windowWithHandle(ev.handle) : self.windowAt((i32)ev.x, (i32)ev.y);
            if (w != (UXWindow*)0)
                {
                keyWindow = w; // clicking a window gives it the keyboard
                w.dispatchMouse(ev);
                }
            }
        else if (k == (u8)UXEventWheel)
            {
            // The wheel acts on the window it happened over (the driver tagged it), not the key window.
            UXWindow* w = self.windowWithHandle(ev.handle);
            if (w != (UXWindow*)0)
                {
                w.dispatchWheel(ev);
                }
            }
        else if (k == (u8)UXEventKeyDown)
            {
            // The KEY WINDOW routes it — not "the first window", which is only ever right by accident.
            if (keyWindow != (UXWindow*)0)
                {
                keyWindow.dispatchKey(ev);
                }
            }
        else if (k == (u8)UXEventMenuSelect)
            {
            // "title object, item object" -> a bound method call (the backend ran the pull-down).
            if (menuBar != (UXMenuBar*)0)
                {
                menuBar.handleSelection(ev.a, ev.b);
                }
            }
        else if (k == (u8)UXEventClose)
            {
            // Close only the window whose close box was hit; quit only when the LAST window goes.
            UXWindow* w = self.windowWithHandle(ev.handle);
            if (w != (UXWindow*)0)
                {
                self.closeWindow(w);
                }
            // untagged close (no handle) -> treat as app quit
            else
                {
                self.stop();
                }
            }
        else if (k == (u8)UXEventRedraw || k == (u8)UXEventMove)
            {
            // We were not told WHAT changed, so assume all of it.
            UXWindow* w = self.windowWithHandle(ev.handle);
            if (w != (UXWindow*)0)
                {
                w.displayAll();
                }
            }
        else if (k == (u8)UXEventResize)
            {
            // Tell the app FIRST (it may anchor/reflow its own views to the new size), THEN displayAll
            // — which re-lays the tree into the new work area and repositions native controls in one
            // pass, seeing the app's new frames.  realizeTree runs inside displayAll, synchronously.
            UXWindow* w = self.windowWithHandle(ev.handle);
            if (w != (UXWindow*)0)
                {
                i32 nw = (i32)0;
                i32 nh = (i32)0;
                gDriver.windowContentGeometry(w.handle, &nw, &nh);
                // Notify observers, then the delegate, THEN reflow — so any layout either does lands in
                // the one displayAll below (which reflows the tree + repositions native controls).
                UXNotificationCenter.shared().postWith(UXWindowDidResizeNotification, (Object*)w, nw, nh);
                if (delegate != (UXApplicationDelegate*)0)
                    {
                    callback f void(UXApplication * app, UXWindow * win, i32 width, i32 height) = &delegate.windowDidResize;
                    if (f)
                        {
                        f(self, w, nw, nh);
                        }
                    }
                w.displayAll();
                }
            }
        }

    UXWindow* windowAt(i32 x, i32 y)
        {
        return self.windowWithHandle(gDriver.windowAtPoint(x, y));
        }

    UXWindow* windowWithHandle(i32 h)
        {
        for (Object* o in windows)
            {
            UXWindow* w = (UXWindow* ?)o;
            if (w != (UXWindow*)0 && w.handle == h)
                {
                return w;
                }
            }
        return (UXWindow*)0;
        }
    }

    // The running application, for code that must repaint mid-modal-loop (a table drag-select or a
    // scrollbar thumb drag) where the run loop is blocked and cannot reach displayIfNeeded itself.
    UXApplication* gApp;
