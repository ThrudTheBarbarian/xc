// libUXAppKit.m — the ObjC/AppKit shim behind UXAppKitDriver.  Compiled with ARC (-fobjc-arc).
//
// It owns every NSRect / ObjC boundary so xtc drives AppKit with primitive signatures only.  The
// UXDrawView subclass is FLIPPED (top-left origin, y down) so the toolkit's coordinates map straight
// through, and its drawRect: is a C trampoline that calls back into the neutral window-draw callback.
//
// Two run modes:
//   * HEADLESS (tests, g_interactive=0): no window shown; paint into an offscreen bitmap via
//     cacheDisplayInRect (with pixel readback); events are synthesized and pulled with a hand pump.
//   * INTERACTIVE (the demo, g_interactive=1): windows are shown and [NSApp run] OWNS the loop.  The
//     content view forwards mouseDown:/keyDown: to the toolkit via a dispatch callback (g_dispatch).
//
// Memory: ARC.  This shim previously did manual MRC and hit a cascade of over-release / premature-
// drain crashes under [NSApp run] (window ordering, _openWindows, the alert window) — ARC gets the
// retain/release/autorelease right so those don't happen.  Objects that CROSS to xtc as `void*`
// (the menu tree) use __bridge / __bridge_retained to hand ARC ownership across the boundary.
#import <Cocoa/Cocoa.h>
#include <sys/time.h>
#import <objc/runtime.h>

#define UX_MAXW 64

typedef void (*ux_content_fn)(int handle, int wx, int wy, int ww, int wh, void* ud);
typedef void (*ux_dispatch_fn)(int kind, int x, int y, int key);

static NSWindow* g_win[UX_MAXW];        // ARC-strong: assignment retains, = nil releases
static NSView* g_view[UX_MAXW];         // the drawing/content view (NSScrollView's document view)
static NSScrollView* g_scroll[UX_MAXW]; // interactive: wraps g_view for native scrolling
static int g_winReqX[UX_MAXW];          // requested top-left (neutral top-left-origin coords)
static int g_winReqY[UX_MAXW];
static ux_content_fn g_contentFn[UX_MAXW];
static void* g_contentUd[UX_MAXW]; // an xtc object (not ObjC) — no bridging
static int g_native = 0;
static Class g_drawViewClass = 0;
static NSBitmapImageRep* g_lastRep = 0;
static int g_interactive = 0;
static int g_quit = 0;
static id g_winDelegate = 0;
static id g_menuTarget = 0;
static ux_dispatch_fn g_dispatch = 0;

void ux_ak_stop(void); // fwd

// ---- the content view: paint seam + (interactive) a real responder --------------------------
static void ak_drawRect(__unsafe_unretained id self, SEL _cmd, NSRect dirty)
    {
    for (int h = 1; h < UX_MAXW; h++)
        {
        if (g_view[h] == (NSView*)self)
            {
            if (g_contentFn[h])
                {
                NSRect b = [(NSView*)self bounds];
                g_contentFn[h](h, 0, 0, (int)b.size.width, (int)b.size.height, g_contentUd[h]);
                }
            return;
            }
        }
    }
static BOOL ak_isFlipped(__unsafe_unretained id self, SEL _cmd)
    {
    return YES;
    }
static BOOL ak_acceptsFirstResponder(__unsafe_unretained id self, SEL _cmd)
    {
    return YES;
    }
static void ak_mouseDown(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id ev)
    {
    if (!g_dispatch)
        return;
    NSPoint p = [(NSView*)self convertPoint:[(NSEvent*)ev locationInWindow] fromView:nil];
    int h = 0;
    for (int i = 1; i < UX_MAXW; i++)
        {
        if (g_view[i] == (NSView*)self)
            {
            h = i;
            break;
            }
        }
    g_dispatch(1, (int)p.x, (int)p.y, h); // route to the window that got the event, not always #1
    }
static void ak_keyDown(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id ev)
    {
    if (!g_dispatch)
        return;
    NSString* ch = [(NSEvent*)ev characters];
    g_dispatch(4, 0, 0, [ch length] > 0 ? (int)[ch characterAtIndex:0] : 0);
    }

static Class ak_view_class(void)
    {
    if (g_drawViewClass)
        return g_drawViewClass;
    Class c = objc_allocateClassPair([NSView class], "UXDrawView", 0);
    class_addMethod(c, sel_registerName("drawRect:"), (IMP)ak_drawRect,
                    "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    class_addMethod(c, sel_registerName("isFlipped"), (IMP)ak_isFlipped, "B@:");
    class_addMethod(c, sel_registerName("acceptsFirstResponder"), (IMP)ak_acceptsFirstResponder, "B@:");
    class_addMethod(c, sel_registerName("mouseDown:"), (IMP)ak_mouseDown, "v@:@");
    class_addMethod(c, sel_registerName("keyDown:"), (IMP)ak_keyDown, "v@:@");
    objc_registerClassPair(c);
    g_drawViewClass = c;
    return c;
    }

/* ── the input shield ────────────────────────────────────────────────────────
 * A bare NSView that covers a region and forwards every press to the toolkit.
 *
 * Controls are flat children of the window's ONE content view, so a toolkit
 * view "on top" is only on top in the SHADOW tree -- AppKit still routes a
 * click to the NSButton under the pointer and the toolkit never sees it.  This
 * is a real NSView, ordered above its siblings, so AppKit's own hit-test finds
 * it first; it then hands the press to the same dispatch the content view uses,
 * in the CONTENT VIEW's coordinates, so everything downstream is unchanged.
 *
 * Transparent and non-opaque: what shows through is the real controls, drawn by
 * AppKit.  That is the point -- a design surface wants the genuine article on
 * screen and only the INPUT intercepted.
 */
static NSView* g_shield[UX_MAXW];
static Class g_shieldClass;
static void ak_shieldMouseDown(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id ev)
    {
    if (!g_dispatch)
        return;
    int h = 0;
    for (int i = 1; i < UX_MAXW; i++)
        {
        if (g_shield[i] == (NSView*)self)
            {
            h = i;
            break;
            }
        }
    if (!h || !g_view[h])
        return;
    /* The content view's coordinates, not the shield's: the toolkit hit-tests
     * the whole window tree, and a point in shield-local space would be short
     * by the shield's own origin. */
    NSPoint p = [g_view[h] convertPoint:[(NSEvent*)ev locationInWindow] fromView:nil];
    g_dispatch(1, (int)p.x, (int)p.y, h);
    }
/* A click into an INACTIVE window is normally swallowed to activate it, and the
 * press never reaches the view -- which is why the shield was found by
 * AppKit's hit-test and still heard nothing.  A design surface wants the
 * opposite: clicking into an editor window that is not frontmost should select
 * what you clicked, not cost you a click.  (Interface Builder behaves this way,
 * and so does every drawing tool.) */
static BOOL ak_acceptsFirstMouse(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id ev)
    {
    return YES;
    }
static Class ak_shield_class(void)
    {
    if (g_shieldClass)
        return g_shieldClass;
    Class c = objc_allocateClassPair([NSView class], "UXShield", 0);
    class_addMethod(c, sel_registerName("isFlipped"), (IMP)ak_isFlipped, "B@:");
    class_addMethod(c, sel_registerName("acceptsFirstMouse:"), (IMP)ak_acceptsFirstMouse, "B@:@");
    class_addMethod(c, sel_registerName("mouseDown:"), (IMP)ak_shieldMouseDown, "v@:@");
    objc_registerClassPair(c);
    g_shieldClass = c;
    return c;
    }
void ux_ak_make_shield(int handle, int x, int y, int w, int h, int hidden)
    {
    NSView* content = g_view[handle];
    if (!content)
        return;
    if (!g_shield[handle])
        {
        NSView* s = [[ak_shield_class() alloc] initWithFrame:NSMakeRect(x, y, w, h)];
        g_shield[handle] = s;
        [content addSubview:s positioned:NSWindowAbove relativeTo:nil];
        }
    else
        {
        [g_shield[handle] setFrame:NSMakeRect(x, y, w, h)];
        }
    /* A hidden shield must stop shielding, or an editor that puts its canvas
     * away leaves an invisible surface eating clicks over whatever replaced it. */
    [g_shield[handle] setHidden:hidden ? YES : NO];
    }
/* Controls realized AFTER the shield would sit above it, so the shield is
 * re-raised at the end of every realize pass.  Cheap, and the alternative is a
 * shield that works until the next widget appears. */
void ux_ak_raise_shield(int handle)
    {
    NSView* content = g_view[handle];
    NSView* s = g_shield[handle];
    if (!content || !s)
        return;
    if ([[content subviews] lastObject] == s)
        return; /* already on top */
    [s removeFromSuperview];
    [content addSubview:s positioned:NSWindowAbove relativeTo:nil];
    }
int ux_ak_has_shield(int handle)
    {
    return g_shield[handle] != nil;
    }

static void ak_windowWillClose(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id note)
    {
    g_quit = 1;
    ux_ak_stop();
    }
// Forward a resize into the toolkit (kind 9), tagged with the window handle, so the neutral layer
// reflows the tree + repositions native controls + notifies the app.  The new size is read back
// through ux_ak_content_geometry.  Deferred to the next run-loop cycle: at end-of-live-resize this is
// already the normal loop, so the reflow (which runs auto-layout via NSButton fittingSize, and the
// toolkit's own retain/weak bookkeeping) never executes inside AppKit's live-resize nested loop —
// doing so crashes deep in CoreGraphics / CoreAutoLayout.
static void ak_schedule_resize(NSWindow* win)
    {
    if (!g_dispatch || !win)
        return;
    int handle = 0;
    for (int h = 1; h < UX_MAXW; h++)
        {
        if (g_win[h] == win)
            {
            handle = h;
            break;
            }
        }
    if (!handle)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (g_win[handle] != win)
          return; // window went away meanwhile
      if (g_dispatch)
          g_dispatch(9, handle, 0, 0);
    });
    }
// During a live drag the document view fills via autoresizing (no toolkit work needed); the reflow
// waits for the drag to END.  A programmatic resize (not live) is handled here directly.
static void ak_windowDidResize(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id note)
    {
    NSWindow* win = [(NSNotification*)note object];
    if ([win inLiveResize])
        return; // handled in windowDidEndLiveResize
    ak_schedule_resize(win);
    }
static void ak_windowDidEndLiveResize(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id note)
    {
    ak_schedule_resize([(NSNotification*)note object]);
    }
static id ak_win_delegate(void)
    {
    if (g_winDelegate)
        return g_winDelegate;
    Class c = objc_allocateClassPair([NSObject class], "UXWinDelegate", 0);
    class_addMethod(c, sel_registerName("windowWillClose:"), (IMP)ak_windowWillClose, "v@:@");
    class_addMethod(c, sel_registerName("windowDidResize:"), (IMP)ak_windowDidResize, "v@:@");
    class_addMethod(c, sel_registerName("windowDidEndLiveResize:"), (IMP)ak_windowDidEndLiveResize, "v@:@");
    objc_registerClassPair(c);
    g_winDelegate = [[c alloc] init];
    return g_winDelegate;
    }

// The NSApplication delegate: quit when the last window closes, the standard macOS behaviour.
static id g_appDelegate = 0;
static BOOL ak_shouldTerminateAfterLastWindow(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id app)
    {
    return YES;
    }
static id ak_app_delegate(void)
    {
    if (g_appDelegate)
        return g_appDelegate;
    Class c = objc_allocateClassPair([NSObject class], "UXAppDelegate", 0);
    class_addMethod(c, sel_registerName("applicationShouldTerminateAfterLastWindowClosed:"),
                    (IMP)ak_shouldTerminateAfterLastWindow, "B@:@");
    objc_registerClassPair(c);
    g_appDelegate = [[c alloc] init];
    return g_appDelegate;
    }

static void ak_menu_action(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id sender)
    {
    int tag = (int)[(NSMenuItem*)sender tag];
    if (g_dispatch)
        g_dispatch(7, tag / 256, tag % 256, 0);
    }
static id ak_menu_target(void)
    {
    if (g_menuTarget)
        return g_menuTarget;
    Class c = objc_allocateClassPair([NSObject class], "UXMenuTarget", 0);
    class_addMethod(c, sel_registerName("xgMenu:"), (IMP)ak_menu_action, "v@:@");
    objc_registerClassPair(c);
    g_menuTarget = [[c alloc] init];
    return g_menuTarget;
    }

// ---- mode + the interactive loop ------------------------------------------------------------
void ux_ak_set_dispatch(void* fn)
    {
    g_dispatch = (ux_dispatch_fn)fn;
    }
int ux_ak_interactive(void)
    {
    return g_interactive;
    }
// Capture mode: headless (no window ever shown), but realizeTree builds the
// REAL NSControls anyway — cacheDisplayInRect renders an unshown hierarchy,
// controls included, which is what the portrait pipeline wants.  A separate
// switch because the headless TESTS assert the app-drawn fallback art.
static int g_capture = 0;
int ux_ak_capture(void)
    {
    return g_capture;
    }
void ux_ak_set_capture(int on)
    {
    g_capture = on;
    }
void ux_ak_set_interactive(int on)
    {
    [NSApplication sharedApplication];
    g_interactive = on;
    if (on)
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    }
void ux_ak_run(void)
    {
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp run];
    }
// the close box was hit -> the neutral loop should end
int ux_ak_quit(void)
    {
    return g_quit;
    }
void ux_ak_stop(void)
    {
    [NSApp stop:nil];
    NSEvent* e = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                    location:NSMakePoint(0, 0)
                               modifierFlags:0
                                   timestamp:0
                                windowNumber:0
                                     context:nil
                                     subtype:0
                                       data1:0
                                       data2:0];
    [NSApp postEvent:e atStart:YES];
    }
/* Auto-quit for the interactive demos: after `ms`, behave exactly as if the
 * close box had been hit -- set the quit flag and break [NSApp run] -- so a demo
 * can be run unattended (a CI sweep, a quick smoke check) without hanging.
 *
 * Deliberately NOT [NSApp terminate:], which ux_ak_quit_after_ms below does:
 * terminate kills the process where it stands, so the demo never returns
 * through its own shutdown, prints nothing on the way out, and any teardown
 * accounting (the memgate's native-object count) is skipped.  A demo that exits
 * differently when unattended is a demo that proves less than it appears to. */
void ux_ak_close_after_ms(int ms)
    {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * 1000000),
                   dispatch_get_main_queue(), ^{
                     /* Dispatch a CLOSE (kind 8), do not merely stop [NSApp run].  Stopping
         * AppKit's loop leaves the NEUTRAL layer still running, so
         * UXApplication.run simply re-enters it and the demo hangs -- which it
         * did, intermittently, depending on whether a stray event happened to
         * arrive first.  Routing it as a close is what makes this identical to
         * the close box: the app stops, the loop unwinds for good. */
                     g_quit = 1;
                     if (g_dispatch)
                         g_dispatch(8, 0, 0, 0); /* UXEventClose, no window */
                     ux_ak_stop();
                   });
    }
void ux_ak_quit_after_ms(int ms)
    {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * 1000000),
                   dispatch_get_main_queue(), ^{
                     [NSApp terminate:nil];
                   });
    }

void ux_ak_boot(void)
    {
    [NSApplication sharedApplication];
    // finishLaunching BEFORE any window is created — in BOTH modes.  It is internally guarded to run
    // once (so [NSApp run] won't redo it), and it sets up NSApp's _openWindows table; creating the
    // main window before it corrupts that table -> the intermittent _openWindows hang/crash on the
    // next window added (e.g. an alert).  (The activation crash I once blamed on a double call was
    // actually the local autoreleasepool, since removed.)
    [NSApp finishLaunching];
    if (g_interactive)
        [NSApp setDelegate:ak_app_delegate()]; // quit when the last window closes
    ak_view_class();
    }

// ---- windows --------------------------------------------------------------------------------
int ux_ak_window_create(int x, int y, int w, int h)
    {
    int handle = 0;
    for (int i = 1; i < UX_MAXW; i++)
        {
        if (g_win[i] == nil)
            {
            handle = i;
            break;
            }
        }
    if (!handle)
        return 0;
    NSWindow* win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(x, y, w, h)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [win setReleasedWhenClosed:NO]; // ARC (g_win) owns the lifetime, not the close machinery
    NSView* v = [[ak_view_class() alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    // wrap in a real NSScrollView for native scrolling
    if (g_interactive)
        {
        NSScrollView* sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
        [sv setHasVerticalScroller:YES];
        [sv setHasHorizontalScroller:YES];
        [sv setAutohidesScrollers:YES];               // no bars until content exceeds the window
        [sv setScrollerStyle:NSScrollerStyleOverlay]; // float over content (no inset -> no feedback)
        [sv setBorderType:NSNoBorder];
        [sv setDrawsBackground:NO];
        [sv setDocumentView:v]; // v is the document view; NSScrollView clips + scrolls it
        // Fill the clip view and track it via AUTORESIZING, so AppKit tiles the document view during a
        // live window resize.  Hand-resizing it inside the resize transaction corrupts CoreGraphics'
        // display list (a crash in CA::Layer display).  A scrolling window drops this in content_size.
        [v setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
        [win setContentView:sv];
        g_scroll[handle] = sv;
        }
    else
        {
        [win setContentView:v]; // headless: draw straight into v (offscreen), no scrolling
        }
    g_win[handle] = win;
    g_view[handle] = v;
    g_winReqX[handle] = x;
    g_winReqY[handle] = y; // remember the requested top-left for window_open
    g_native++;
    return handle;
    }
void ux_ak_window_set_content(int handle, void* fn, void* ud)
    {
    g_contentFn[handle] = (ux_content_fn)fn;
    g_contentUd[handle] = ud;
    }
// The window's current top-left in neutral (top-left-origin) screen coords — for verifying placement.
void ux_ak_window_topleft(int handle, int* x, int* y)
    {
    *x = -1;
    *y = -1;
    if (handle < 0 || handle >= UX_MAXW)
        return;
    NSWindow* win = g_win[handle];
    if (!win)
        return;
    NSScreen* scr = [win screen] ? [win screen] : [NSScreen mainScreen];
    if (!scr)
        return;
    NSRect f = [win frame];
    CGFloat top = scr.frame.origin.y + scr.frame.size.height;
    *x = (int)f.origin.x;
    *y = (int)(top - (f.origin.y + f.size.height));
    }
void ux_ak_window_open(int handle)
    {
    if (!g_interactive)
        return;
    NSWindow* win = g_win[handle];
    if (!win)
        return;
    [win setDelegate:ak_win_delegate()];
    // Honour the requested position instead of centring every window.  Neutral coords are top-left
    // origin (like GEM/Win32); AppKit screen coords are bottom-left, so flip Y against the screen top.
    NSScreen* scr = [win screen] ? [win screen] : [NSScreen mainScreen];
    if (scr)
        {
        CGFloat top = scr.frame.origin.y + scr.frame.size.height;
        [win setFrameTopLeftPoint:NSMakePoint(g_winReqX[handle], top - g_winReqY[handle])];
        }
    [win makeKeyAndOrderFront:nil];
    [win makeFirstResponder:g_view[handle]];
    }
// Raise an already-open window to the front and make it key (a Windows-menu pick).
void ux_ak_window_front(int handle)
    {
    if (!g_interactive)
        return;
    NSWindow* win = g_win[handle];
    if (!win)
        return;
    [NSApp activateIgnoringOtherApps:YES];
    [win makeKeyAndOrderFront:nil];
    }
void ux_ak_window_close(int handle)
    {
    if (!g_win[handle])
        return;
    [g_win[handle] close];
    g_win[handle] = nil;
    g_view[handle] = nil;
    g_scroll[handle] = nil; // ARC releases
    g_shield[handle] = nil;
    g_contentFn[handle] = 0;
    g_contentUd[handle] = 0;
    g_native--;
    }
void ux_ak_window_set_title(int handle, const char* s)
    {
    if (!g_win[handle])
        return;
    [g_win[handle] setTitle:[NSString stringWithUTF8String:s]];
    }
// Window chrome the toolkit has had since the GEM backend and AppKit never implemented.  A window
// that reports itself modified draws a dot in its close button here, exactly as GEM draws WT_MODIFIED
// in the title bar; a subtitle is the smaller second line macOS 11 added.  respondsToSelector rather
// than a version check, so an older system simply keeps the plain title.
void ux_ak_window_set_subtitle(int handle, const char* s)
    {
    if (!g_win[handle])
        return;
    if ([g_win[handle] respondsToSelector:@selector(setSubtitle:)])
        [g_win[handle] setSubtitle:[NSString stringWithUTF8String:s ? s : ""]];
    }
void ux_ak_window_set_modified(int handle, int on)
    {
    if (!g_win[handle])
        return;
    [g_win[handle] setDocumentEdited:on ? YES : NO];
    }
// Read-back, so a test can assert the WINDOW changed rather than that the call returned.
int ux_ak_window_modified(int handle)
    {
    return g_win[handle] ? ([g_win[handle] isDocumentEdited] ? 1 : 0) : 0;
    }
int ux_ak_window_subtitle(int handle, char* out, int cap)
    {
    if (out && cap > 0)
        out[0] = 0;
    if (!g_win[handle] || !out || cap <= 0)
        return 0;
    if (![g_win[handle] respondsToSelector:@selector(subtitle)])
        return 0;
    NSString* t = [g_win[handle] subtitle];
    if (!t)
        return 0;
    snprintf(out, (size_t)cap, "%s", [t UTF8String]);
    return 1;
    }

void ux_ak_window_invalidate(int handle)
    {
    NSView* v = g_view[handle];
    if (!v)
        return;
    if (g_interactive)
        {
        [v setNeedsDisplay:YES];
        return;
        }
    NSRect b = [v bounds];
    NSBitmapImageRep* rep = [v bitmapImageRepForCachingDisplayInRect:b];
    if (rep)
        {
        [v cacheDisplayInRect:b toBitmapImageRep:rep];
        g_lastRep = rep;
        }
    }
int ux_ak_native_count(void)
    {
    return g_native;
    }

// Scrolling (interactive): report the content extent -> the document view grows to it, and
// NSScrollView shows native scrollers + scrolls it.  The toolkit does NOT shift the tree
// (windowScrollY returns 0), so there is no double offset — NSScrollView owns the scroll.
void ux_ak_content_size(int handle, int w, int h)
    {
    if (handle < 0 || handle >= UX_MAXW)
        return;
    NSView* v = g_view[handle];
    if (!v || !g_scroll[handle])
        return;
    // A scrolling window: the document view IS the content extent (fixed height -> vertical scroll),
    // and only its WIDTH follows the clip view (so the content spans the window, no needless
    // horizontal bar).  Autoresizing does the width tracking; nothing hand-resizes it during a drag.
    [v setFrame:NSMakeRect(0, 0, w, h)];
    [v setAutoresizingMask:NSViewWidthSizable];
    }
// programmatic scroll (flipped: top-left)
void ux_ak_set_scroll(int handle, int x, int y)
    {
    NSView* v = g_view[handle];
    if (v && g_scroll[handle])
        [v scrollPoint:NSMakePoint(x, y)];
    }
// The window's current content-area size (grows/shrinks as the user drags the frame).
void ux_ak_content_geometry(int handle, int* w, int* h)
    {
    NSWindow* win = g_win[handle];
    NSRect b = win ? [[win contentView] bounds] : NSZeroRect;
    if (w)
        *w = (int)b.size.width;
    if (h)
        *h = (int)b.size.height;
    }

// ---- drawing vocabulary (current NSGraphicsContext) -----------------------------------------
void ux_ak_fill(int x, int y, int w, int h, int r, int g, int b)
    {
    [[NSColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(x, y, w, h));
    }
void ux_ak_text(const char* s, int x, int y, int r, int g, int b, int size)
    {
    NSFont* f = [NSFont systemFontOfSize:(size > 0 ? size : 12)];
    NSDictionary* a = @{NSForegroundColorAttributeName :
                            [NSColor colorWithRed:r / 255.0
                                            green:g / 255.0
                                             blue:b / 255.0
                                            alpha:1.0],
                        NSFontAttributeName : f};
    [[NSString stringWithUTF8String:s] drawAtPoint:NSMakePoint(x, y) withAttributes:a];
    }
// How wide a string renders in the UI font — what the toolkit breaks lines with.  Rounded UP: a
// fractional width that rounds down puts a line one pixel over the measure and it wraps short.
int ux_ak_text_width(const char* s, int size)
    {
    NSFont* f = [NSFont systemFontOfSize:(size > 0 ? size : 12)];
    NSDictionary* a = @{NSFontAttributeName : f};
    NSSize sz = [[NSString stringWithUTF8String:s] sizeWithAttributes:a];
    return (int)ceil(sz.width);
    }
// The offset in force right now, in minutes east of UTC — tm_gmtoff has DST already applied.
int ux_ak_local_offset_minutes(void)
    {
    time_t t = time(NULL);
    struct tm l;
    localtime_r(&t, &l);
    return (int)(l.tm_gmtoff / 60);
    }
// The wall clock as UTC civil components: y, mo, d, h, mi, s, us.
void ux_ak_now_utc(int* out7)
    {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    time_t secs = (time_t)tv.tv_sec;
    struct tm g;
    gmtime_r(&secs, &g);
    out7[0] = g.tm_year + 1900;
    out7[1] = g.tm_mon + 1;
    out7[2] = g.tm_mday;
    out7[3] = g.tm_hour;
    out7[4] = g.tm_min;
    out7[5] = g.tm_sec;
    out7[6] = (int)tv.tv_usec;
    }
// ── persistent settings ──────────────────────────────────────────────────────────────────────
// NSUserDefaults, which is what UXKeyValueStore was modelled on in the first place — so on macOS
// the toolkit's settings are just defaults, visible to `defaults read` like any other app's.  A
// named DOMAIN becomes a suite; the shared domain is the standard suite.  Everything is stored as
// a string: the toolkit owns the type, and a suite is not the place to argue about it.
static NSUserDefaults* ux_ak_defaults(const char* domain)
    {
    if (!domain || !*domain)
        return [NSUserDefaults standardUserDefaults];
    NSUserDefaults* d = [[NSUserDefaults alloc] initWithSuiteName:@(domain)];
    return d ?: [NSUserDefaults standardUserDefaults];
    }
int ux_ak_setting_get(const char* domain, const char* key, char* out, int cap)
    {
    if (out && cap > 0)
        out[0] = 0;
    if (!key || !out || cap <= 0)
        return 0;
    NSString* v = [ux_ak_defaults(domain) stringForKey:@(key)];
    if (!v)
        return 0;
    snprintf(out, (size_t)cap, "%s", [v UTF8String]);
    return 1;
    }
int ux_ak_setting_set(const char* domain, const char* key, const char* value)
    {
    if (!key || !value)
        return 0;
    NSUserDefaults* d = ux_ak_defaults(domain);
    [d setObject:@(value) forKey:@(key)];
    [d synchronize]; // a test (or a crash) must not lose the write to the flush timer
    return 1;
    }
int ux_ak_setting_remove(const char* domain, const char* key)
    {
    if (!key)
        return 0;
    NSUserDefaults* d = ux_ak_defaults(domain);
    [d removeObjectForKey:@(key)];
    [d synchronize];
    return 1;
    }

// Milliseconds since first call — a monotonic base, so the toolkit only ever sees differences.
int ux_ak_now_ms(void)
    {
    static double base = 0;
    double now = [[NSProcessInfo processInfo] systemUptime];
    if (base == 0)
        base = now;
    return (int)((now - base) * 1000.0);
    }
// Styled measurement — the counterpart of ux_ak_text_font, and it must agree with it.
int ux_ak_text_width_font(const char* s, const char* family, int size, int bold, int italic)
    {
    CGFloat sz = size > 0 ? size : 12;
    NSFont* f = family && *family ? [NSFont fontWithName:[NSString stringWithUTF8String:family] size:sz] : nil;
    if (!f)
        f = [NSFont systemFontOfSize:sz];
    NSFontManager* fm = [NSFontManager sharedFontManager];
    if (bold)
        f = [fm convertFont:f toHaveTrait:NSBoldFontMask];
    if (italic)
        f = [fm convertFont:f toHaveTrait:NSItalicFontMask];
    NSSize z = [[NSString stringWithUTF8String:s] sizeWithAttributes:@{NSFontAttributeName : f}];
    return (int)ceil(z.width);
    }
// Styled text: a named family + bold/italic (the toolkit font-chooser preview).
void ux_ak_text_font(const char* s, int x, int y, int r, int g, int b,
                     const char* family, int size, int bold, int italic)
    {
    CGFloat sz = size > 0 ? size : 12;
    NSFont* f = [NSFont fontWithName:[NSString stringWithUTF8String:family] size:sz];
    if (!f)
        f = [NSFont systemFontOfSize:sz];
    NSFontManager* fm = [NSFontManager sharedFontManager];
    if (bold)
        f = [fm convertFont:f toHaveTrait:NSBoldFontMask];
    if (italic)
        f = [fm convertFont:f toHaveTrait:NSItalicFontMask];
    NSDictionary* a = @{NSForegroundColorAttributeName :
                            [NSColor colorWithRed:r / 255.0
                                            green:g / 255.0
                                             blue:b / 255.0
                                            alpha:1.0],
                        NSFontAttributeName : f};
    [[NSString stringWithUTF8String:s] drawAtPoint:NSMakePoint(x, y) withAttributes:a];
    }
// A filled polygon from a flat x,y,x,y... array — the general form of ux_ak_tri, and what the
// neutral painter hands down for stroke quads, joins, caps and gradient bands alike.
void ux_ak_poly(const short* xy, int n, int r, int g, int b)
    {
    if (n < 3)
        return;
    [[NSColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1.0] setFill];
    NSBezierPath* p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(xy[0], xy[1])];
    for (int i = 1; i < n; i++)
        [p lineToPoint:NSMakePoint(xy[i * 2], xy[i * 2 + 1])];
    [p closePath];
    [p fill];
    }
// Stroke a path NATIVELY: build an NSBezierPath from the op run and let Cocoa stroke it.  This is
// the whole point of the native path — Cocoa draws the CURVE, not a polyline approximation of it, at
// sub-pixel precision with its own joins, so the silhouette is a true offset of the bezier instead of
// an offset of a polyline whose vertices were rounded to whole pixels.
//   caps: 0 = butt, 1 = round, 2 = square (UXCAP_*); an arrowhead is drawn as a polygon, not here.
// NSBezierPath has ONE line cap for the whole path, so when the two ends differ the rounder of the
// two wins and the other end is covered by whatever shape the painter puts there.
void ux_ak_stroke_path(const int* ops, int n, int width, int startCap, int endCap,
                       int r, int g, int b)
    {
    if (n <= 0)
        return;
    NSBezierPath* p = [NSBezierPath bezierPath];
    int i = 0;
    BOOL started = NO;
    while (i < n)
        {
        int op = ops[i++];
        // MOVE
        if (op == 0)
            {
            if (i + 2 > n)
                break;
            [p moveToPoint:NSMakePoint(ops[i], ops[i + 1])];
            i += 2;
            started = YES;
            }
        // LINE
        else if (op == 1)
            {
            if (i + 2 > n)
                break;
            if (!started)
                {
                [p moveToPoint:NSMakePoint(ops[i], ops[i + 1])];
                started = YES;
                }
            else
                {
                [p lineToPoint:NSMakePoint(ops[i], ops[i + 1])];
                }
            i += 2;
            }
        // CURVE
        else if (op == 2)
            {
            if (i + 6 > n)
                break;
            if (!started)
                {
                [p moveToPoint:NSMakePoint(ops[i + 4], ops[i + 5])];
                started = YES;
                }
            else
                {
                [p curveToPoint:NSMakePoint(ops[i + 4], ops[i + 5])
                    controlPoint1:NSMakePoint(ops[i], ops[i + 1])
                    controlPoint2:NSMakePoint(ops[i + 2], ops[i + 3])];
                }
            i += 6;
            }
        // CLOSE
        else if (op == 3)
            {
            if (started)
                [p closePath];
            }
        else
            break;
        }
    [p setLineWidth:(CGFloat)width];
    int cap = startCap > endCap ? startCap : endCap;
    [p setLineCapStyle:(cap == 1 ? NSLineCapStyleRound
                                 : (cap == 2 ? NSLineCapStyleSquare : NSLineCapStyleButt))];
    [p setLineJoinStyle:NSLineJoinStyleRound];
    [[NSColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1.0] setStroke];
    [p stroke];
    }

void ux_ak_tri(int x0, int y0, int x1, int y1, int x2, int y2, int r, int g, int b)
    {
    [[NSColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1.0] setFill];
    NSBezierPath* p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(x0, y0)];
    [p lineToPoint:NSMakePoint(x1, y1)];
    [p lineToPoint:NSMakePoint(x2, y2)];
    [p closePath];
    [p fill];
    }

// ---- headless event pump (tests only) -------------------------------------------------------
void ux_ak_post_quit(void)
    {
    g_quit = 1;
    }
// Headless: drive a resize through the neutral path (nextEvent returns kind 9) without a live drag.
static int g_pendingResize = 0; // count of pending synthetic resizes
static int g_pendingResizeHandle = 0;
void ux_ak_post_resize(int handle, int w, int h)
    {
    NSWindow* win = g_win[handle];
    if (win)
        [win setContentSize:NSMakeSize(w, h)]; // autoresizing re-tiles the document view
    g_pendingResizeHandle = handle;
    g_pendingResize++;
    }
void ux_ak_post_click(int handle, int tx, int ty)
    {
    NSWindow* win = g_win[handle];
    NSView* v = g_view[handle];
    if (!win || !v)
        return;
    NSPoint wp = [v convertPoint:NSMakePoint(tx, ty) toView:nil];
    // A full down+up click: a native NSButton fires on the release, not the press.
    for (NSEventType et = NSEventTypeLeftMouseDown;; et = NSEventTypeLeftMouseUp)
        {
        NSEvent* e = [NSEvent mouseEventWithType:et
                                        location:wp
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:[win windowNumber]
                                         context:nil
                                     eventNumber:0
                                      clickCount:1
                                        pressure:1.0];
        [NSApp postEvent:e atStart:NO];
        if (et == NSEventTypeLeftMouseUp)
            break;
        }
    }
void ux_ak_post_key(int ch)
    {
    NSString* s = [NSString stringWithFormat:@"%C", (unichar)ch];
    NSEvent* e = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                  location:NSMakePoint(0, 0)
                             modifierFlags:0
                                 timestamp:0
                              windowNumber:0
                                   context:nil
                                characters:s
               charactersIgnoringModifiers:s
                                 isARepeat:NO
                                   keyCode:0];
    [NSApp postEvent:e atStart:NO];
    }
int ux_ak_next_event(int timeoutMs, int* kind, int* x, int* y, int* key)
    {
    *kind = 0;
    *x = 0;
    *y = 0;
    *key = 0;
    // headless resize
    if (g_pendingResize > 0)
        {
        g_pendingResize--;
        *kind = 9;
        *x = g_pendingResizeHandle;
        return 9;
        }
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    NSEvent* e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                    untilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]
                                       inMode:NSDefaultRunLoopMode
                                      dequeue:YES];
    if (!e)
        {
        *kind = g_quit ? 8 : 0;
        return *kind;
        }
    NSEventType t = [e type];
    if (t == NSEventTypeLeftMouseDown)
        {
        NSView* v = [[e window] contentView];
        NSPoint p = v ? [v convertPoint:[e locationInWindow] fromView:nil] : [e locationInWindow];
        *kind = 1;
        *x = (int)p.x;
        *y = (int)p.y;
        }
    else if (t == NSEventTypeKeyDown)
        {
        NSString* chars = [e characters];
        *kind = 4;
        *key = ([chars length] > 0 ? (int)[chars characterAtIndex:0] : 0);
        }
    else
        {
        [NSApp sendEvent:e];
        *kind = 0;
        }
    return *kind;
    }

// ---- menus (NSMenu).  The menu tree crosses to xtc as void*, so ARC ownership is bridged: the
// bar is __bridge_retained out (xtc holds a +1; menus live for the app), submenus are borrowed. ---
void* ux_ak_menu_new(void)
    {
    return (__bridge_retained void*)[[NSMenu alloc] initWithTitle:@""];
    }
void* ux_ak_menu_add_title(void* bar, const char* title)
    {
    NSMenu* b = (__bridge NSMenu*)bar;
    NSString* t = [NSString stringWithUTF8String:title];
    NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:t action:NULL keyEquivalent:@""];
    NSMenu* sub = [[NSMenu alloc] initWithTitle:t];
    [sub setAutoenablesItems:NO];
    [it setSubmenu:sub];        // item retains sub
    [b addItem:it];             // bar retains it
    return (__bridge void*)sub; // borrowed (owned by the item chain, which the bar keeps alive)
    }
void ux_ak_menu_add_item(void* sub, const char* text, int tag, int checked, int disabled, int sep)
    {
    NSMenu* s = (__bridge NSMenu*)sub;
    if (sep)
        {
        [s addItem:[NSMenuItem separatorItem]];
        return;
        }
    NSMenuItem* it = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithUTF8String:text]
               action:sel_registerName("xgMenu:")
        keyEquivalent:@""];
    [it setTag:tag];
    [it setTarget:ak_menu_target()];
    [it setState:(checked ? NSControlStateValueOn : NSControlStateValueOff)];
    [it setEnabled:(disabled ? NO : YES)];
    [s addItem:it];
    }
void ux_ak_menu_set_main(void* bar)
    {
    [NSApp setMainMenu:(__bridge NSMenu*)bar];
    }
static NSMenuItem* ak_find_tag(NSMenu* bar, int tag)
    {
    for (NSMenuItem* top in [bar itemArray])
        {
        NSMenu* sub = [top submenu];
        if (sub)
            for (NSMenuItem* it in [sub itemArray])
                {
                if ([it tag] == tag)
                    return it;
                }
        }
    return nil;
    }
void ux_ak_menu_check(void* bar, int tag, int on)
    {
    NSMenuItem* it = ak_find_tag((__bridge NSMenu*)bar, tag);
    if (it)
        [it setState:(on ? NSControlStateValueOn : NSControlStateValueOff)];
    }
void ux_ak_menu_enable(void* bar, int tag, int on)
    {
    NSMenuItem* it = ak_find_tag((__bridge NSMenu*)bar, tag);
    if (it)
        [it setEnabled:(on ? YES : NO)];
    }

// ---- a modal alert (NSAlert) ----------------------------------------------------------------
int ux_ak_alert(int icon, const char* lines, const char* buttons, int defaultBtn)
    {
    NSAlert* a = [[NSAlert alloc] init];
    [a setAlertStyle:(icon >= 3 ? NSAlertStyleCritical : NSAlertStyleInformational)];
    NSArray* ls = [[NSString stringWithUTF8String:lines] componentsSeparatedByString:@"|"];
    [a setMessageText:[ls count] > 0 ? ls[0] : @""];
    if ([ls count] > 1)
        {
        NSRange r = NSMakeRange(1, [ls count] - 1);
        [a setInformativeText:[[ls subarrayWithRange:r] componentsJoinedByString:@"\n"]];
        }
    NSArray* bs = [[NSString stringWithUTF8String:buttons] componentsSeparatedByString:@"|"];
    for (NSString* b in bs)
        [a addButtonWithTitle:b];
    return (int)([a runModal] - NSAlertFirstButtonReturn) + 1;
    }

// A native NSOpenPanel.  Writes the chosen path (UTF-8) into out and returns 1; returns 0 on Cancel.
int ux_ak_open_panel(const char* prompt, const char* startDir, char* out, int outCap)
    {
    if (!g_interactive)
        return 0;
    NSOpenPanel* p = [NSOpenPanel openPanel];
    [p setCanChooseFiles:YES];
    [p setCanChooseDirectories:NO];
    [p setAllowsMultipleSelection:NO];
    if (prompt && *prompt)
        [p setPrompt:[NSString stringWithUTF8String:prompt]];
    if (startDir && *startDir)
        [p setDirectoryURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:startDir]]];
    if ([p runModal] != NSModalResponseOK)
        return 0;
    NSString* path = [[p URL] path];
    if (!path)
        return 0;
    strncpy(out, [path UTF8String], outCap - 1);
    out[outCap - 1] = 0;
    return 1;
    }

// ---- a native colour picker (NSColorPanel, run modally) -------------------------------------
// NSColorPanel is a shared, non-modal panel, so give it an accessory view with OK/Cancel and run a
// modal session around it; the buttons end the session.  Returns 1 + the chosen sRGB, or 0 on Cancel.
@interface UXColorDone : NSObject
- (void)ok:(id)sender;
- (void)cancel:(id)sender;
@end
@implementation UXColorDone
- (void)ok:(id)sender
    {
    [NSApp stopModalWithCode:1];
    }
- (void)cancel:(id)sender
    {
    [NSApp stopModalWithCode:0];
    }
@end

int ux_ak_color_panel(int r, int g, int b, int* outR, int* outG, int* outB)
    {
    if (!g_interactive)
        return 0;
    NSColorPanel* cp = [NSColorPanel sharedColorPanel];
    [cp setShowsAlpha:NO];
    [cp setColor:[NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1.0]];

    UXColorDone* done = [[UXColorDone alloc] init];
    NSView* acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 40)];
    NSButton* cancel = [[NSButton alloc] initWithFrame:NSMakeRect(20, 6, 100, 30)];
    [cancel setTitle:@"Cancel"];
    [cancel setBezelStyle:NSBezelStyleRounded];
    [cancel setTarget:done];
    [cancel setAction:@selector(cancel:)];
    NSButton* ok = [[NSButton alloc] initWithFrame:NSMakeRect(128, 6, 100, 30)];
    [ok setTitle:@"Select"];
    [ok setBezelStyle:NSBezelStyleRounded];
    [ok setKeyEquivalent:@"\r"];
    [ok setTarget:done];
    [ok setAction:@selector(ok:)];
    [acc addSubview:cancel];
    [acc addSubview:ok];
    [cp setAccessoryView:acc];
    [cp makeKeyAndOrderFront:nil];

    NSInteger rc = [NSApp runModalForWindow:cp];
    [cp setAccessoryView:nil];
    [cp orderOut:nil];
    if (rc != 1)
        return 0;
    NSColor* c = [[cp color] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    *outR = (int)([c redComponent] * 255.0 + 0.5);
    *outG = (int)([c greenComponent] * 255.0 + 0.5);
    *outB = (int)([c blueComponent] * 255.0 + 0.5);
    return 1;
    }

// ---- a native font picker (NSFontPanel, run modally) ----------------------------------------
// Like the colour panel: run the shared font panel modally with an OK/Cancel accessory.  The panel drives
// NSFontManager via changeFont:, so we accumulate the selection into `font` and read it back on OK.
@interface UXFontDone : NSObject
@property(strong) NSFont* font;
@property NSInteger code;
- (void)changeFont:(id)sender;
- (void)ok:(id)sender;
- (void)cancel:(id)sender;
@end
@implementation UXFontDone
// panel change -> new font
- (void)changeFont:(id)sender
    {
    self.font = [sender convertFont:self.font];
    }
- (void)ok:(id)sender
    {
    self.code = 1;
    [NSApp stopModal];
    }
- (void)cancel:(id)sender
    {
    self.code = 0;
    [NSApp stopModal];
    }
@end

int ux_ak_font_panel(const char* inFamily, int inSize, int inBold, int inItalic,
                     char* outFamily, int outCap, int* outSize, int* outBold, int* outItalic)
    {
    if (!g_interactive)
        return 0;
    NSFontManager* fm = [NSFontManager sharedFontManager];
    CGFloat sz = inSize > 0 ? inSize : 12;
    NSFont* init = [NSFont fontWithName:[NSString stringWithUTF8String:inFamily] size:sz];
    if (!init)
        init = [NSFont systemFontOfSize:sz];
    NSFontTraitMask tr = 0;
    if (inBold)
        tr |= NSBoldFontMask;
    if (inItalic)
        tr |= NSItalicFontMask;
    if (tr)
        init = [fm convertFont:init toHaveTrait:tr];

    UXFontDone* done = [[UXFontDone alloc] init];
    done.font = init;
    done.code = 0;
    [fm setAction:@selector(changeFont:)];
    [fm setTarget:done]; // route the panel's changeFont: to us
    [fm setSelectedFont:init isMultiple:NO];

    NSFontPanel* fp = [fm fontPanel:YES];
    NSView* acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 40)];
    NSButton* cancel = [[NSButton alloc] initWithFrame:NSMakeRect(20, 6, 100, 30)];
    [cancel setTitle:@"Cancel"];
    [cancel setBezelStyle:NSBezelStyleRounded];
    [cancel setTarget:done];
    [cancel setAction:@selector(cancel:)];
    NSButton* ok = [[NSButton alloc] initWithFrame:NSMakeRect(128, 6, 100, 30)];
    [ok setTitle:@"Select"];
    [ok setBezelStyle:NSBezelStyleRounded];
    [ok setKeyEquivalent:@"\r"];
    [ok setTarget:done];
    [ok setAction:@selector(ok:)];
    [acc addSubview:cancel];
    [acc addSubview:ok];
    [fp setAccessoryView:acc];
    [fp makeKeyAndOrderFront:nil];

    NSInteger rc = [NSApp runModalForWindow:fp];
    [fp setAccessoryView:nil];
    [fp orderOut:nil];
    [fm setTarget:nil];
    if (rc != 1)
        return 0;

    NSFont* chosen = done.font ? done.font : init;
    const char* fam = [[chosen familyName] UTF8String];
    strncpy(outFamily, fam, outCap - 1);
    outFamily[outCap - 1] = 0;
    *outSize = (int)([chosen pointSize] + 0.5);
    NSFontTraitMask ct = [fm traitsOfFont:chosen];
    *outBold = (ct & NSBoldFontMask) ? 1 : 0;
    *outItalic = (ct & NSItalicFontMask) ? 1 : 0;
    return 1;
    }

// ---- native controls (option A: real AppKit widgets overlaying the shadow tree) -------------
// Interactive mode replaces drawn button/field imitations with real NSButton/NSTextField subviews
// for genuine native look + feel.  A control's click/edit routes back into the toolkit (a button
// forwards a synthetic click at its centre, so the shadow node's UXControl fires unchanged), so app
// source is untouched.  Keyed by (window handle, tree node index).
static NSView* g_ctl[UX_MAXW][256]; // ARC-strong; [handle][node] -> native control (or nil)
static id g_button_target = 0;
typedef void (*ux_ctlfire_fn)(int handle, int node);
static ux_ctlfire_fn g_control_fire = 0;
void ux_ak_set_control_fire(void* fn)
    {
    g_control_fire = (ux_ctlfire_fn)fn;
    }

// A value-carrying variant, for controls whose "action" reports a NUMBER (slider/stepper/popup/
// segmented): (handle, node, integerValue).  Live, not deferred — a slider drag needs each step.
typedef void (*ux_valuechanged_fn)(int handle, int node, int value);
static ux_valuechanged_fn g_value_changed = 0;
static id g_value_target = 0;
void ux_ak_set_value_changed(void* fn)
    {
    g_value_changed = (ux_valuechanged_fn)fn;
    }
static void ak_value_action(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id sender)
    {
    int tag = (int)[(NSControl*)sender tag];
    int v; // "value" means index for a popup/segmented
    if ([sender isKindOfClass:[NSPopUpButton class]])
        v = (int)[(NSPopUpButton*)sender indexOfSelectedItem];
    else if ([sender isKindOfClass:[NSSegmentedControl class]])
        v = (int)[(NSSegmentedControl*)sender selectedSegment];
    else
        v = (int)[(NSControl*)sender integerValue];
    if (g_value_changed)
        g_value_changed(tag / 1000, tag % 1000, v);
    }
static id ak_value_target(void)
    {
    if (g_value_target)
        return g_value_target;
    Class c = objc_allocateClassPair([NSObject class], "UXValueTarget", 0);
    class_addMethod(c, sel_registerName("xgVal:"), (IMP)ak_value_action, "v@:@");
    objc_registerClassPair(c);
    g_value_target = [[c alloc] init];
    return g_value_target;
    }
// A native NSSlider bound to the peer UXSlider by (handle,node) tag.
void ux_ak_make_slider(int handle, int node, int x, int y, int w, int h, int lo, int hi, int val)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= 256)
        return;
    NSSlider* s = [[NSSlider alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [s setMinValue:lo];
    [s setMaxValue:hi];
    [s setIntegerValue:val];
    [s setContinuous:YES]; // fire during the drag, not only on release
    [s setTag:(handle * 1000 + node)];
    [s setTarget:ak_value_target()];
    [s setAction:sel_registerName("xgVal:")];
    [content addSubview:s];
    g_ctl[handle][node] = s;
    }
void ux_ak_set_slider_value(int handle, int node, int val)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= 256)
        return;
    id c = g_ctl[handle][node];
    if ([c isKindOfClass:[NSSlider class]])
        {
        [(NSSlider*)c setIntegerValue:val];
        }
    }
// A native NSPopUpButton bound to the peer UXPopUpButton.
void ux_ak_make_popup(int handle, int node, int x, int y, int w, int h)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= 256)
        return;
    NSPopUpButton* p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, y, w, h) pullsDown:NO];
    [p setTag:(handle * 1000 + node)];
    [p setTarget:ak_value_target()];
    [p setAction:sel_registerName("xgVal:")];
    [content addSubview:p];
    g_ctl[handle][node] = p;
    }
void ux_ak_popup_add_item(int handle, int node, const char* title)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= 256)
        return;
    id c = g_ctl[handle][node];
    if ([c isKindOfClass:[NSPopUpButton class]])
        {
        [(NSPopUpButton*)c addItemWithTitle:[NSString stringWithUTF8String:(title ? title : "")]];
        }
    }
void ux_ak_popup_select(int handle, int node, int i)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= 256)
        return;
    id c = g_ctl[handle][node];
    if ([c isKindOfClass:[NSPopUpButton class]] && i >= 0)
        {
        [(NSPopUpButton*)c selectItemAtIndex:i];
        }
    }
// A native NSStepper.
void ux_ak_make_stepper(int handle, int node, int x, int y, int w, int h, int lo, int hi, int step, int wraps, int val)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= 256)
        return;
    NSStepper* s = [[NSStepper alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [s setMinValue:lo];
    [s setMaxValue:hi];
    [s setIncrement:step];
    [s setValueWraps:(wraps ? YES : NO)];
    [s setIntegerValue:val];
    [s setTag:(handle * 1000 + node)];
    [s setTarget:ak_value_target()];
    [s setAction:sel_registerName("xgVal:")];
    [content addSubview:s];
    g_ctl[handle][node] = s;
    }
void ux_ak_set_stepper_value(int handle, int node, int val)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= 256)
        return;
    id c = g_ctl[handle][node];
    if ([c isKindOfClass:[NSStepper class]])
        {
        [(NSStepper*)c setIntegerValue:val];
        }
    }
// A native NSSegmentedControl.
void ux_ak_make_segmented(int handle, int node, int x, int y, int w, int h, int nseg)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= 256)
        return;
    NSSegmentedControl* sc = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [sc setSegmentCount:nseg];
    [sc setTag:(handle * 1000 + node)];
    [sc setTarget:ak_value_target()];
    [sc setAction:sel_registerName("xgVal:")];
    [content addSubview:sc];
    g_ctl[handle][node] = sc;
    }
void ux_ak_seg_set_label(int handle, int node, int seg, const char* label)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= 256)
        return;
    id c = g_ctl[handle][node];
    if ([c isKindOfClass:[NSSegmentedControl class]] && seg >= 0)
        {
        [(NSSegmentedControl*)c setLabel:[NSString stringWithUTF8String:(label ? label : "")] forSegment:seg];
        }
    }
void ux_ak_seg_select(int handle, int node, int seg)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= 256)
        return;
    id c = g_ctl[handle][node];
    if ([c isKindOfClass:[NSSegmentedControl class]] && seg >= 0)
        {
        [(NSSegmentedControl*)c setSelectedSegment:seg];
        }
    }
// A native NSProgressIndicator (output only).
void ux_ak_make_progress(int handle, int node, int x, int y, int w, int h)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= 256)
        return;
    NSProgressIndicator* p = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [p setStyle:NSProgressIndicatorStyleBar];
    [p setIndeterminate:NO];
    [p setMinValue:0];
    [p setMaxValue:1000];
    [content addSubview:p];
    g_ctl[handle][node] = p;
    }
void ux_ak_set_progress(int handle, int node, int mille, int indeterminate)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= 256)
        return;
    id c = g_ctl[handle][node];
    if (![c isKindOfClass:[NSProgressIndicator class]])
        return;
    NSProgressIndicator* p = (NSProgressIndicator*)c;
    if (indeterminate)
        {
        [p setIndeterminate:YES];
        [p startAnimation:nil];
        }
    else
        {
        [p setIndeterminate:NO];
        [p setDoubleValue:mille];
        // Force an immediate redraw.  setDoubleValue only marks the bar needsDisplay, and during a
        // native NSSlider's modal drag the runloop is busy tracking the mouse — so the bar's redraw is
        // coalesced and doesn't land until the drag pauses ("drag, wait, it jumps").  [display] draws now.
        [p display];
        }
    }

static void ak_button_action(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id sender)
    {
    // Fire the control's neutral action DIRECTLY (by its (handle,node) tag), not via a synthetic
    // click at the frame centre — the hit-test round-trip was unreliable (Clear never fired, and a
    // checkbox snapped back because its toggle was lost).  Still DEFERRED to the next run-loop cycle:
    // the action may open a modal, and running that nested in AppKit's sendAction: stack corrupts
    // window teardown (a UAF in _openWindows); at the top of the loop it behaves like a normal modal.
    int tag = (int)[(NSButton*)sender tag];
    int handle = tag / 1000, node = tag % 1000;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (g_control_fire)
          g_control_fire(handle, node);
    });
    }
static id ak_button_target(void)
    {
    if (g_button_target)
        return g_button_target;
    Class c = objc_allocateClassPair([NSObject class], "UXButtonTarget", 0);
    class_addMethod(c, sel_registerName("xgBtn:"), (IMP)ak_button_action, "v@:@");
    objc_registerClassPair(c);
    g_button_target = [[c alloc] init];
    return g_button_target;
    }

int ux_ak_has_control(int handle, int node)
    {
    return (node >= 0 && node < 256 && g_ctl[handle][node] != nil) ? 1 : 0;
    }
// How many native subview controls exist for a window (g_ctl slots) — for verifying realization.
int ux_ak_control_count(int handle)
    {
    if (handle < 0 || handle >= UX_MAXW)
        return 0;
    int n = 0;
    for (int i = 0; i < 256; i++)
        {
        if (g_ctl[handle][i])
            n++;
        }
    return n;
    }

// A native NSTextField syncs with the toolkit's field buffer: native edits are written back (so
// field.text() works), and setText from the app is pushed to the field (so e.g. Clear Field shows).
static id g_field_delegate = 0;
static char* g_field_buf[UX_MAXW][256]; // raw ptr to the toolkit's field buffer (not ObjC)
static int g_field_cap[UX_MAXW][256];
static void (*g_field_changed)(int, int) = 0; // -> the neutral field's onChange (handle, node)
void ux_ak_set_field_hooks(void* changed)
    {
    g_field_changed = (void (*)(int, int))changed;
    }
static void ak_field_changed(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id note)
    {
    NSTextField* tf = [(NSNotification*)note object];
    int tag = (int)[tf tag], handle = tag / 1000, node = tag % 1000;
    char* buf = g_field_buf[handle][node];
    int cap = g_field_cap[handle][node];
    if (!buf || cap <= 0)
        return;
    const char* s = [[tf stringValue] UTF8String];
    if (!s)
        s = "";
    int i = 0;
    while (s[i] && i < cap - 1)
        {
        buf[i] = s[i];
        i++;
        }
    buf[i] = 0;
    if (g_field_changed)
        g_field_changed(handle, node); // fire the neutral field's onChange
    }
static id ak_field_delegate(void)
    {
    if (g_field_delegate)
        return g_field_delegate;
    Class c = objc_allocateClassPair([NSObject class], "UXFieldDelegate", 0);
    class_addMethod(c, sel_registerName("controlTextDidChange:"), (IMP)ak_field_changed, "v@:@");
    objc_registerClassPair(c);
    g_field_delegate = [[c alloc] init];
    return g_field_delegate;
    }
void ux_ak_make_field(int handle, int node, int x, int y, int w, int h, char* buf, int cap, int secure)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= 256)
        return;
    NSTextField* tf = secure ? [[NSSecureTextField alloc] initWithFrame:NSMakeRect(x, y, w, h)]
                             : [[NSTextField alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [tf setStringValue:(buf ? [NSString stringWithUTF8String:buf] : @"")];
    [tf setEditable:YES];
    [tf setSelectable:YES];
    [tf setBezeled:YES];
    [tf setBezelStyle:NSTextFieldSquareBezel];
    [tf setTag:(handle * 1000 + node)];
    [tf setDelegate:ak_field_delegate()];
    [content addSubview:tf];
    g_ctl[handle][node] = tf;
    g_field_buf[handle][node] = buf;
    g_field_cap[handle][node] = cap;
    }

void ux_ak_set_field_placeholder(int handle, int node, char* text)
    {
    if (node < 0 || node >= 256)
        return;
    NSView* v = g_ctl[handle][node];
    if (!v || ![v isKindOfClass:[NSTextField class]])
        return;
    [(NSTextField*)v setPlaceholderString:(text ? [NSString stringWithUTF8String:text] : @"")];
    }
// Push the buffer into the field IF it differs (so app setText propagates, but a normal repaint
// during editing — where buffer == field — leaves the caret alone).
void ux_ak_update_field(int handle, int node)
    {
    if (node < 0 || node >= 256)
        return;
    NSTextField* tf = (NSTextField*)g_ctl[handle][node];
    char* buf = g_field_buf[handle][node];
    if (!tf || !buf)
        return;
    NSString* want = [NSString stringWithUTF8String:buf];
    if (![[tf stringValue] isEqualToString:want])
        [tf setStringValue:want];
    }
// A native label: a non-editable, borderless, transparent NSTextField (system font).
void ux_ak_make_label(int handle, int node, int x, int y, int w, int h, const char* text)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= 256)
        return;
    NSTextField* tf = [NSTextField labelWithString:[NSString stringWithUTF8String:text]];
    [tf setFrame:NSMakeRect(x, y, w, h)];
    [tf setLineBreakMode:NSLineBreakByTruncatingTail]; // too narrow -> "…", not a hard clip
    [content addSubview:tf];
    g_ctl[handle][node] = tf;
    }
void ux_ak_set_label_text(int handle, int node, const char* text)
    {
    if (node < 0 || node >= 256)
        return;
    NSTextField* tf = (NSTextField*)g_ctl[handle][node];
    if (!tf)
        return;
    NSString* want = [NSString stringWithUTF8String:text];
    if (![[tf stringValue] isEqualToString:want])
        [tf setStringValue:want];
    }
// A rounded push button has a fixed native height (~21pt); a taller app frame stretches the bezel.
// Keep the app's x/width but use the button's natural height, centred vertically in the frame.
static void ak_place_button(NSButton* b, int x, int y, int w, int h)
    {
    CGFloat nh = [b fittingSize].height;
    if (nh <= 0 || nh > h)
        nh = h;
    [b setFrame:NSMakeRect(x, y + (h - nh) / 2.0, w, nh)];
    }
void ux_ak_make_button(int handle, int node, int x, int y, int w, int h, const char* title)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= 256)
        return;
    NSButton* b = [[NSButton alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [b setTitle:[NSString stringWithUTF8String:title]];
    [b setBezelStyle:NSBezelStyleRounded]; // the standard rounded push button
    [b setTag:(handle * 1000 + node)];     // so ak_button_action fires the right node
    [b setTarget:ak_button_target()];
    [b setAction:sel_registerName("xgBtn:")];
    ak_place_button(b, x, y, w, h); // native height, centred in the app's frame
    [content addSubview:b];
    g_ctl[handle][node] = b;
    }
// A native check box (NSButtonTypeSwitch) or radio button (NSButtonTypeRadio).  Clicking toggles the
// native state AND fires the same xgBtn: target -> a synthetic click -> the neutral widget toggles;
// realizeTree then pushes the model state back with ux_ak_set_control_check.  So the app's
// UXCheckbox/UXRadioGroup stays authoritative and the control shows the OS look.
// flags: bit0 = checked, bit1 = isRadio.  Packed into ONE arg so the call stays at 8 parameters —
// a 9th would be stack-passed on arm64, which xtc currently mis-marshals, so
// `isRadio` arrived as garbage and the check box was built as a radio.
void ux_ak_make_check(int handle, int node, int x, int y, int w, int h,
                      const char* title, int flags)
    {
    int checked = flags & 1, isRadio = (flags >> 1) & 1;
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= 256)
        return;
    NSString* t = [NSString stringWithUTF8String:(title ? title : "")];
    id tgt = ak_button_target();
    SEL sel = sel_registerName("xgBtn:");
    // The factory methods set the right button type + bezel (a square check box / a round radio).
    NSButton* b = isRadio ? [NSButton radioButtonWithTitle:t target:tgt action:sel]
                          : [NSButton checkboxWithTitle:t target:tgt action:sel];
    [b setFrame:NSMakeRect(x, y, w, h)];
    [b setState:(checked ? NSControlStateValueOn : NSControlStateValueOff)];
    [b setTag:(handle * 1000 + node)];
    [content addSubview:b];
    g_ctl[handle][node] = b;
    }
// Text alignment on a label or field: 0 left, 1 centre, 2 right.  A column of
// "Name:" / "Size:" labels only lines its colons up when the text is right
// aligned in boxes whose right edges agree.
void ux_ak_set_control_align(int handle, int node, int a)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= 256)
        return;
    NSView* v = g_ctl[handle][node];
    if (![v respondsToSelector:@selector(setAlignment:)])
        return;
    /* UX_ALIGN_*: 0 left, 1 right, 2 centre -- GEM's te_just numbering. */
    NSTextAlignment na = a == 1   ? NSTextAlignmentRight
                         : a == 2 ? NSTextAlignmentCenter
                                  : NSTextAlignmentLeft;
    [(NSTextField*)v setAlignment:na];
    }
// Read it back, so a gate can tell "the flag was set" from "the text moved".
int ux_ak_control_align(int handle, int node)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= 256)
        return -1;
    NSView* v = g_ctl[handle][node];
    if (![v respondsToSelector:@selector(alignment)])
        return -1;
    NSTextAlignment na = [(NSTextField*)v alignment];
    return na == NSTextAlignmentRight ? 1 : na == NSTextAlignmentCenter ? 2
                                                                        : 0;
    }
void ux_ak_set_control_check(int handle, int node, int on)
    {
    if (node < 0 || node >= 256)
        return;
    NSButton* b = (NSButton*)g_ctl[handle][node];
    if ([b isKindOfClass:[NSButton class]])
        [b setState:(on ? NSControlStateValueOn : NSControlStateValueOff)];
    }
void ux_ak_set_control_frame(int handle, int node, int x, int y, int w, int h)
    {
    if (node < 0 || node >= 256)
        return;
    NSView* v = g_ctl[handle][node];
    if (!v)
        return;
    if ([v isKindOfClass:[NSButton class]])
        ak_place_button((NSButton*)v, x, y, w, h);
    else
        [v setFrame:NSMakeRect(x, y, w, h)];
    }
void ux_ak_set_control_enabled(int handle, int node, int on)
    {
    if (node < 0 || node >= 256)
        return;
    NSView* v = g_ctl[handle][node];
    if ([v isKindOfClass:[NSControl class]])
        [(NSControl*)v setEnabled:(on ? YES : NO)];
    }
// Read the control's ACTUAL enabled state back.  A test that only checks the
// toolkit's shadow flag cannot tell "we set the flag" from "the control
// changed" — which is exactly the bug this exists to catch.  -1 = no control.
int ux_ak_control_enabled(int handle, int node)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= 256)
        return -1;
    NSView* v = g_ctl[handle][node];
    if (!v)
        return -1;
    if (![v respondsToSelector:@selector(isEnabled)])
        return -1;
    return [(NSControl*)v isEnabled] ? 1 : 0;
    }
// The toggle's ACTUAL on/off state, for the same reason as ux_ak_control_enabled:
// a checkbox or radio whose peer field says "selected" while the NSButton on
// screen still says "off" is precisely the bug a shadow-only assertion misses.
// -1 = no control, or one that does not have a state.
int ux_ak_control_check(int handle, int node)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= 256)
        return -1;
    NSView* v = g_ctl[handle][node];
    if (![v isKindOfClass:[NSButton class]])
        return -1;
    return [(NSButton*)v state] == NSControlStateValueOn ? 1 : 0;
    }
// The control's ACTUAL frame, for the same reason as ux_ak_control_enabled:
// a gate must be able to tell "the shadow tree was updated" from "the control
// moved".  Returns 0 when there is no control.  Coordinates are the shim's
// own (top-left origin), matching what set_control_frame was handed.
int ux_ak_control_frame(int handle, int node, int* x, int* y, int* w, int* h)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= 256)
        return 0;
    NSView* v = g_ctl[handle][node];
    if (!v)
        return 0;
    NSRect f = [v frame];
    NSView* host = [v superview];
    CGFloat top = host ? [host bounds].size.height - f.origin.y - f.size.height : f.origin.y;
    if (x)
        *x = (int)f.origin.x;
    if (y)
        *y = (int)top;
    if (w)
        *w = (int)f.size.width;
    if (h)
        *h = (int)f.size.height;
    return 1;
    }
void ux_ak_set_control_hidden(int handle, int node, int on)
    {
    if (node < 0 || node >= 256)
        return;
    NSView* v = g_ctl[handle][node];
    if (v)
        [v setHidden:(on ? YES : NO)];
    }
// Springs & struts (UX_ANCHOR_* | UX_FLEX_*, see UXViewDriver.xt) -> NSView autoresizing mask, so
// AppKit tracks the control LIVE during a window drag.  A spring is a FLEXIBLE margin: to pin to an
// edge, the OPPOSITE margin springs.  The document view is FLIPPED (y down), so top is the min-Y
// edge and bottom the max-Y edge.  Default (0) -> NSViewNotSizable = pinned top-left, fixed size.
enum
    {
    UX_A_LEFT = 1,
    UX_A_RIGHT = 2,
    UX_A_TOP = 4,
    UX_A_BOTTOM = 8,
    UX_F_WIDTH = 16,
    UX_F_HEIGHT = 32
    };
void ux_ak_set_control_autoresize(int handle, int node, int mask)
    {
    if (node < 0 || node >= 256)
        return;
    NSView* v = g_ctl[handle][node];
    if (!v)
        return;
    NSAutoresizingMaskOptions m = NSViewNotSizable;
    if (mask & UX_F_WIDTH)
        m |= NSViewWidthSizable;
    if (mask & UX_F_HEIGHT)
        m |= NSViewHeightSizable;
    if ((mask & UX_A_RIGHT) && !(mask & UX_A_LEFT))
        m |= NSViewMinXMargin; // pin right: left springs
    if ((mask & UX_A_LEFT) && (mask & UX_A_RIGHT))
        m |= NSViewWidthSizable; // both -> stretch width
    if ((mask & UX_A_BOTTOM) && !(mask & UX_A_TOP))
        m |= NSViewMinYMargin; // pin bottom (flipped)
    if ((mask & UX_A_TOP) && (mask & UX_A_BOTTOM))
        m |= NSViewHeightSizable; // both -> stretch height
    [v setAutoresizingMask:m];
    }

// ---- native NSTableView (a list/table overlaying the peer UXTableView) -----------------------
// The NSTableView pulls its data through hooks the driver registers, each taking the peer
// UXTableView pointer: so the SAME neutral datasource that materialises the GEM row/cell subtree
// feeds the native table, and a row click routes back to UXTableView.selectRow (the app's
// tableSelectionDidChange fires unchanged).
typedef int (*ux_tbl_rows_fn)(void* peer);
typedef const char* (*ux_tbl_cell_fn)(void* peer, int row, int col);
typedef int (*ux_tbl_cols_fn)(void* peer);
typedef const char* (*ux_tbl_title_fn)(void* peer, int col);
typedef int (*ux_tbl_width_fn)(void* peer, int col);
typedef int (*ux_tbl_multi_fn)(void* peer);
typedef void (*ux_tbl_selset_fn)(void* peer, int* rows, int n);
static ux_tbl_rows_fn g_tbl_rows = 0;
static ux_tbl_cell_fn g_tbl_cell = 0;
static ux_tbl_cols_fn g_tbl_cols = 0;
static ux_tbl_title_fn g_tbl_title = 0;
static ux_tbl_width_fn g_tbl_width = 0;
static ux_tbl_multi_fn g_tbl_multi = 0;
static ux_tbl_selset_fn g_tbl_selset = 0;
void ux_ak_set_table_hooks(void* rows, void* cell, void* cols, void* title, void* width,
                           void* multi, void* selset)
    {
    g_tbl_rows = (ux_tbl_rows_fn)rows;
    g_tbl_cell = (ux_tbl_cell_fn)cell;
    g_tbl_cols = (ux_tbl_cols_fn)cols;
    g_tbl_title = (ux_tbl_title_fn)title;
    g_tbl_width = (ux_tbl_width_fn)width;
    g_tbl_multi = (ux_tbl_multi_fn)multi;
    g_tbl_selset = (ux_tbl_selset_fn)selset;
    }

static int g_tbl_reloading = 0; // guard: a reload's selection-restore must not read back as a click

@interface UXTableSource : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(assign, nonatomic) void* peer; // the UXTableView (raw xtc pointer, not ARC-managed)
@end
@implementation UXTableSource
- (NSInteger)numberOfRowsInTableView:(NSTableView*)tv
    {
    return (self.peer && g_tbl_rows) ? g_tbl_rows(self.peer) : 0;
    }
- (NSView*)tableView:(NSTableView*)tv viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row
    {
    // An NSTableCellView holding an NSTextField pinned to the row's vertical centre.  A bare
    // NSTextField as the cell view top-aligns its text in a tall row; the centreY constraint is the
    // reliable native way to keep it centred at any row height.
    NSTableCellView* cv = [tv makeViewWithIdentifier:@"xgcell" owner:self];
    if (!cv)
        {
        cv = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cv.identifier = @"xgcell";
        NSTextField* tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.bordered = NO;
        tf.editable = NO;
        tf.selectable = NO;
        tf.drawsBackground = NO;
        tf.backgroundColor = [NSColor clearColor];
        tf.usesSingleLineMode = YES;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        tf.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [cv addSubview:tf];
        cv.textField = tf;
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor
                                             constant:2],
            [tf.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor
                                              constant:-2],
            [tf.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
        ]];
        }
    int c = col.identifier ? [col.identifier intValue] : 0;
    const char* s = (self.peer && g_tbl_cell) ? g_tbl_cell(self.peer, (int)row, c) : "";
    cv.textField.stringValue = s ? [NSString stringWithUTF8String:s] : @"";
    return cv;
    }
- (void)tableViewSelectionDidChange:(NSNotification*)note
    {
    if (g_tbl_reloading)
        return; // our own selection-restore after reloadData, not a click
    NSTableView* tv = [note object];
    if (!self.peer || !g_tbl_selset)
        return;
    NSIndexSet* sel = [tv selectedRowIndexes];
    int n = (int)[sel count];
    int stackrows[64];
    int* rows = (n <= 64) ? stackrows : (int*)malloc(sizeof(int) * (n ? n : 1));
    __block int k = 0;
    [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
      rows[k++] = (int)idx;
    }];
    g_tbl_selset(self.peer, rows, n); // the whole selected set, ascending
    if (rows != stackrows)
        free(rows);
    }
@end

static UXTableSource* g_tbl_src[UX_MAXW][256]; // ARC-strong: one datasource per table node

void ux_ak_make_table(int handle, int node, int x, int y, int w, int h, void* peer)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= 256)
        return;
    NSScrollView* sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [sv setHasVerticalScroller:YES];
    [sv setBorderType:NSBezelBorder];
    NSTableView* tv = [[NSTableView alloc] initWithFrame:[[sv contentView] bounds]];
    [tv setUsesAlternatingRowBackgroundColors:YES];
    [tv setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];
    [tv setAllowsMultipleSelection:((peer && g_tbl_multi && g_tbl_multi(peer)) ? YES : NO)];
    int ncols = (peer && g_tbl_cols) ? g_tbl_cols(peer) : 0;
    if (ncols <= 0)
        ncols = 1;
    for (int c = 0; c < ncols; c++)
        {
        NSTableColumn* tc = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%d", c]];
        const char* ti = (peer && g_tbl_title) ? g_tbl_title(peer, c) : "";
        [[tc headerCell] setStringValue:(ti ? [NSString stringWithUTF8String:ti] : @"")];
        int cw = (peer && g_tbl_width) ? g_tbl_width(peer, c) : 80;
        [tc setWidth:(cw > 0 ? cw : 80)];
        [tv addTableColumn:tc];
        }
    UXTableSource* src = [[UXTableSource alloc] init];
    src.peer = peer;
    [tv setDataSource:src];
    [tv setDelegate:src];
    [sv setDocumentView:tv];
    [content addSubview:sv];
    g_ctl[handle][node] = sv;      // the scroll view is the positioned/hidden widget
    g_tbl_src[handle][node] = src; // keep the datasource alive
    [tv reloadData];
    }
void ux_ak_table_reload(int handle, int node)
    {
    if (node < 0 || node >= 256)
        return;
    NSScrollView* sv = (NSScrollView*)g_ctl[handle][node];
    if (![sv isKindOfClass:[NSScrollView class]])
        return;
    NSTableView* tv = (NSTableView*)[sv documentView];
    // reloadData clears the selection; a repaint must not lose it (the app repaints on every row
    // click, to update its own views).  Save + restore the FULL set (multi-select), guarded so the
    // restore is not read back as a fresh click that would re-fire the delegate and repaint again.
    NSIndexSet* sel = [tv selectedRowIndexes];
    NSInteger nrows = [tv numberOfRows];
    NSMutableIndexSet* keep = [NSMutableIndexSet indexSet];
    [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
      if ((NSInteger)idx < nrows)
          [keep addIndex:idx];
    }];
    g_tbl_reloading = 1;
    [tv reloadData];
    if ([keep count])
        [tv selectRowIndexes:keep byExtendingSelection:NO];
    g_tbl_reloading = 0;
    }

// Put a selection INTO the table (replay, or app code).  g_tbl_reloading is the same guard the
// reload above uses: without it selectRowIndexes comes straight back through
// tableViewSelectionDidChange as "the user clicked", and the model we are copying FROM is rewritten
// underneath us mid-push.
void ux_ak_table_select(int handle, int node, int* rows, int n)
    {
    if (node < 0 || node >= 256)
        return;
    NSScrollView* sv = (NSScrollView*)g_ctl[handle][node]; // the table rides in a scroll view
    if (![sv isKindOfClass:[NSScrollView class]])
        return;
    NSTableView* tv = (NSTableView*)[sv documentView];
    if (!tv)
        return;
    NSMutableIndexSet* set = [NSMutableIndexSet indexSet];
    for (int i = 0; i < n; i++)
        if (rows[i] >= 0 && rows[i] < [tv numberOfRows])
            [set addIndex:(NSUInteger)rows[i]];
    g_tbl_reloading = 1;
    if ([set count])
        [tv selectRowIndexes:set byExtendingSelection:NO];
    else
        [tv deselectAll:nil];
    g_tbl_reloading = 0;
    }

// ---- native NSOutlineView (a TREE overlaying the peer UXOutlineView) --------------------------
// Item-based, like an outline datasource: the control asks for the children/value of an ITEM, which
// is the app's node.  A node is a raw xtc pointer, not an ObjC object, so it is boxed in an NSValue
// for the control to hold (NSValue equality is pointer equality, which is exactly the item identity
// NSOutlineView needs for its expansion state).  Columns/selection reuse the table hooks.
typedef int (*ux_ol_children_fn)(void* peer, void* item);
typedef void* (*ux_ol_child_fn)(void* peer, void* item, int i);
typedef int (*ux_ol_expandable_fn)(void* peer, void* item);
typedef const char* (*ux_ol_value_fn)(void* peer, void* item, int col);
typedef void (*ux_ol_didexpand_fn)(void* peer, void* item, int on);
static ux_ol_children_fn g_ol_children = 0;
static ux_ol_child_fn g_ol_child = 0;
static ux_ol_expandable_fn g_ol_expandable = 0;
static ux_ol_value_fn g_ol_value = 0;
static ux_ol_didexpand_fn g_ol_didexpand = 0;
void ux_ak_set_outline_hooks(void* children, void* child, void* expandable, void* value, void* didexpand)
    {
    g_ol_children = (ux_ol_children_fn)children;
    g_ol_child = (ux_ol_child_fn)child;
    g_ol_expandable = (ux_ol_expandable_fn)expandable;
    g_ol_value = (ux_ol_value_fn)value;
    g_ol_didexpand = (ux_ol_didexpand_fn)didexpand;
    }

@interface UXOutlineSource : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property(assign, nonatomic) void* peer;
@end
@implementation UXOutlineSource
- (NSInteger)outlineView:(NSOutlineView*)ov numberOfChildrenOfItem:(id)item
    {
    void* it = item ? [(NSValue*)item pointerValue] : NULL;
    return (self.peer && g_ol_children) ? g_ol_children(self.peer, it) : 0;
    }
- (id)outlineView:(NSOutlineView*)ov child:(NSInteger)i ofItem:(id)item
    {
    void* it = item ? [(NSValue*)item pointerValue] : NULL;
    void* c = (self.peer && g_ol_child) ? g_ol_child(self.peer, it, (int)i) : NULL;
    return c ? [NSValue valueWithPointer:c] : nil;
    }
- (BOOL)outlineView:(NSOutlineView*)ov isItemExpandable:(id)item
    {
    void* it = item ? [(NSValue*)item pointerValue] : NULL;
    return (self.peer && g_ol_expandable && it && g_ol_expandable(self.peer, it)) ? YES : NO;
    }
- (id)outlineView:(NSOutlineView*)ov objectValueForTableColumn:(NSTableColumn*)col byItem:(id)item
    {
    void* it = item ? [(NSValue*)item pointerValue] : NULL;
    int c = col.identifier ? [col.identifier intValue] : 0;
    const char* s = (self.peer && g_ol_value && it) ? g_ol_value(self.peer, it, c) : "";
    return s ? [NSString stringWithUTF8String:s] : @"";
    }
// The native control owns the expand/collapse UX; mirror it into the neutral outline so its flattened
// row list (which native selection is reported against) stays in step.
- (void)outlineViewItemDidExpand:(NSNotification*)note
    {
    id item = [note.userInfo objectForKey:@"NSObject"];
    if (self.peer && g_ol_didexpand && item)
        g_ol_didexpand(self.peer, [(NSValue*)item pointerValue], 1);
    }
- (void)outlineViewItemDidCollapse:(NSNotification*)note
    {
    id item = [note.userInfo objectForKey:@"NSObject"];
    if (self.peer && g_ol_didexpand && item)
        g_ol_didexpand(self.peer, [(NSValue*)item pointerValue], 0);
    }
- (void)outlineViewSelectionDidChange:(NSNotification*)note
    {
    if (g_tbl_reloading)
        return;
    NSOutlineView* ov = [note object];
    if (!self.peer || !g_tbl_selset)
        return;
    NSIndexSet* sel = [ov selectedRowIndexes];
    int n = (int)[sel count];
    int stackrows[64];
    int* rows = (n <= 64) ? stackrows : (int*)malloc(sizeof(int) * (n ? n : 1));
    __block int k = 0;
    [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
      rows[k++] = (int)idx;
    }];
    g_tbl_selset(self.peer, rows, n);
    if (rows != stackrows)
        free(rows);
    }
@end

static UXOutlineSource* g_ol_src[UX_MAXW][256];

// ---- native NSToolbar (window chrome, with the customization sheet + icon/text modes) ----------
@interface UXToolbarDelegate : NSObject <NSToolbarDelegate>
@property(assign, nonatomic) int handle;
@property(assign, nonatomic) int node;
@property(strong, nonatomic) NSMutableArray* order;       // NSToolbarItemIdentifiers, default order
@property(strong, nonatomic) NSMutableDictionary* labels; // ident -> NSString
@property(strong, nonatomic) NSMutableDictionary* tagmap; // ident -> NSNumber
@end
@implementation UXToolbarDelegate
- (NSArray*)toolbarDefaultItemIdentifiers:(NSToolbar*)tb
    {
    return self.order;
    }
- (NSArray*)toolbarAllowedItemIdentifiers:(NSToolbar*)tb
    {
    NSMutableArray* a = [self.order mutableCopy];
    if (![a containsObject:NSToolbarFlexibleSpaceItemIdentifier])
        [a addObject:NSToolbarFlexibleSpaceItemIdentifier];
    if (![a containsObject:NSToolbarSpaceItemIdentifier])
        [a addObject:NSToolbarSpaceItemIdentifier];
    return a;
    }
- (NSToolbarItem*)toolbar:(NSToolbar*)tb itemForItemIdentifier:(NSString*)ident willBeInsertedIntoToolbar:(BOOL)flag
    {
    NSToolbarItem* it = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    NSString* label = self.labels[ident] ?: ident;
    [it setLabel:label];
    [it setPaletteLabel:label];
    NSImage* img = nil; // a generic icon so icon-only mode shows something
    if (@available(macOS 11.0, *))
        {
        img = [NSImage imageWithSystemSymbolName:@"square.grid.2x2" accessibilityDescription:label];
        }
    if (!img)
        img = [NSImage imageNamed:NSImageNameActionTemplate];
    [it setImage:img];
    [it setTarget:self];
    [it setAction:@selector(xgToolbarClicked:)];
    [it setTag:[self.tagmap[ident] intValue]];
    return it;
    }
- (void)xgToolbarClicked:(NSToolbarItem*)sender
    {
    if (g_value_changed)
        g_value_changed(self.handle, self.node, (int)[sender tag]);
    }
@end
static id g_tb_delegate[UX_MAXW];        // keep each window's delegate alive
static NSMutableArray* g_tb_build_order; // scratch during begin/add/install
static NSMutableDictionary *g_tb_build_labels, *g_tb_build_tags;

void ux_ak_toolbar_begin(int handle, int node)
    {
    (void)handle;
    (void)node;
    g_tb_build_order = [NSMutableArray array];
    g_tb_build_labels = [NSMutableDictionary dictionary];
    g_tb_build_tags = [NSMutableDictionary dictionary];
    }
void ux_ak_toolbar_add(int handle, int node, int tag, const char* label, int type)
    {
    (void)handle;
    (void)node;
    NSString* ident;
    if (type == 2)
        ident = NSToolbarFlexibleSpaceItemIdentifier; // UXTB_FLEX
    else if (type == 1)
        ident = NSToolbarSpaceItemIdentifier; // UXTB_SPACE
    else if (type == 3)
        return; // UXTB_SEP: NSToolbar has no separator item
    // UXTB_ITEM
    else
        {
        ident = [NSString stringWithFormat:@"xgtb_%d", tag];
        g_tb_build_labels[ident] = [NSString stringWithUTF8String:(label ? label : "")];
        g_tb_build_tags[ident] = @(tag);
        }
    [g_tb_build_order addObject:ident];
    }
void ux_ak_toolbar_install(int handle, int node)
    {
    if (handle < 0 || handle >= UX_MAXW)
        return;
    NSWindow* win = g_win[handle];
    if (!win)
        return;
    UXToolbarDelegate* d = [[UXToolbarDelegate alloc] init];
    d.handle = handle;
    d.node = node;
    d.order = g_tb_build_order;
    d.labels = g_tb_build_labels;
    d.tagmap = g_tb_build_tags;
    NSToolbar* tb = [[NSToolbar alloc] initWithIdentifier:[NSString stringWithFormat:@"ux_%d_%d", handle, node]];
    [tb setDelegate:d];
    [tb setAllowsUserCustomization:YES]; // right-click -> Customize Toolbar + icon/text modes
    [tb setDisplayMode:NSToolbarDisplayModeIconAndLabel];
    [win setToolbar:tb];
    g_tb_delegate[handle] = d; // retain past this call
    }

// Test hook (bug 020 regression guard): programmatically expand row 0's item — exercises the SAME path a
// triangle click drives (outlineViewItemDidExpand: -> didexpand hook + redraw), without AppKit's
// mouse-tracking loop that synthetic postEvent can't satisfy.  Returns the new visible row count.
int ux_ak_dbg_expand_row0(int handle)
    {
    if (handle < 0 || handle >= UX_MAXW)
        return -1;
    for (int n = 0; n < 256; n++)
        {
        id ctl = g_ctl[handle][n];
        if ([ctl isKindOfClass:[NSScrollView class]] && [[(NSScrollView*)ctl documentView] isKindOfClass:[NSOutlineView class]])
            {
            NSOutlineView* ov = (NSOutlineView*)[(NSScrollView*)ctl documentView];
            id item = [ov itemAtRow:0];
            [ov expandItem:item];
            return (int)[ov numberOfRows];
            }
        }
    return -1;
    }
void ux_ak_make_outline(int handle, int node, int x, int y, int w, int h, void* peer)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= 256)
        return;
    NSScrollView* sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [sv setHasVerticalScroller:YES];
    [sv setBorderType:NSBezelBorder];
    NSOutlineView* ov = [[NSOutlineView alloc] initWithFrame:[[sv contentView] bounds]];
    [ov setAllowsMultipleSelection:((peer && g_tbl_multi && g_tbl_multi(peer)) ? YES : NO)];
    int ncols = (peer && g_tbl_cols) ? g_tbl_cols(peer) : 0;
    if (ncols <= 0)
        ncols = 1;
    NSTableColumn* first = nil;
    for (int c = 0; c < ncols; c++)
        {
        NSTableColumn* tc = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%d", c]];
        const char* ti = (peer && g_tbl_title) ? g_tbl_title(peer, c) : "";
        [[tc headerCell] setStringValue:(ti ? [NSString stringWithUTF8String:ti] : @"")];
        int cw = (peer && g_tbl_width) ? g_tbl_width(peer, c) : 120;
        [tc setWidth:(cw > 0 ? cw : 120)];
        [ov addTableColumn:tc];
        if (c == 0)
            first = tc;
        }
    [ov setOutlineTableColumn:first]; // the column that carries the disclosure triangles + indent
    UXOutlineSource* src = [[UXOutlineSource alloc] init];
    src.peer = peer;
    [ov setDataSource:src];
    [ov setDelegate:src];
    [sv setDocumentView:ov];
    [content addSubview:sv];
    g_ctl[handle][node] = sv;
    g_ol_src[handle][node] = src;
    [ov reloadData];
    }
void ux_ak_outline_reload(int handle, int node)
    {
    if (node < 0 || node >= 256)
        return;
    NSScrollView* sv = (NSScrollView*)g_ctl[handle][node];
    if (![sv isKindOfClass:[NSScrollView class]])
        return;
    NSOutlineView* ov = (NSOutlineView*)[sv documentView];
    [ov reloadData];
    }

// ---- native NSScrollView (a generic scroller over a peer UXScrollView) ------------------------
// Its document view is a flipped NSView whose drawRect calls back to draw the peer's SUBTREE — the
// neutral side sets the draw offset to the document's absolute position first, so the subtree lands at
// this surface's 0,0.  NSScrollView owns the scroll offset + scroller + wheel; the neutral bar is off.
static void (*g_scroll_content)(void* sv, int docW, int docH) = 0;
void ux_ak_set_scroll_content(void* fn)
    {
    g_scroll_content = (void (*)(void*, int, int))fn;
    }

#define UX_MAXSCROLLDOC 128
static NSView* g_scrolldoc_view[UX_MAXSCROLLDOC];
static void* g_scrolldoc_sv[UX_MAXSCROLLDOC];
static int g_scrolldoc_n = 0;

static void ak_scrolldoc_drawRect(__unsafe_unretained id self, SEL _cmd, NSRect dirty)
    {
    for (int i = 0; i < g_scrolldoc_n; i++)
        {
        if (g_scrolldoc_view[i] == (NSView*)self)
            {
            if (g_scroll_content)
                {
                NSRect b = [(NSView*)self bounds];
                g_scroll_content(g_scrolldoc_sv[i], (int)b.size.width, (int)b.size.height);
                }
            return;
            }
        }
    }
static Class ak_scrolldoc_class(void)
    {
    static Class c = nil;
    if (c)
        return c;
    c = objc_allocateClassPair([NSView class], "UXScrollDoc", 0);
    class_addMethod(c, sel_registerName("drawRect:"), (IMP)ak_scrolldoc_drawRect,
                    "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    class_addMethod(c, sel_registerName("isFlipped"), (IMP)ak_isFlipped, "B@:");
    objc_registerClassPair(c);
    return c;
    }

void ux_ak_make_scroll(int handle, int node, int x, int y, int w, int h, int contentH, void* sv)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= 256)
        return;
    NSScrollView* nsv = [[NSScrollView alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [nsv setHasVerticalScroller:YES];
    [nsv setBorderType:NSBezelBorder];
    NSSize cs = [nsv contentSize];
    int dh = contentH > (int)cs.height ? contentH : (int)cs.height;
    NSView* doc = [[ak_scrolldoc_class() alloc] initWithFrame:NSMakeRect(0, 0, cs.width, dh)];
    if (g_scrolldoc_n < UX_MAXSCROLLDOC)
        {
        g_scrolldoc_view[g_scrolldoc_n] = doc;
        g_scrolldoc_sv[g_scrolldoc_n] = sv;
        g_scrolldoc_n++;
        }
    [nsv setDocumentView:doc];
    [content addSubview:nsv];
    g_ctl[handle][node] = nsv;
    [doc setNeedsDisplay:YES];
    }
// Drive the NSScrollView from the toolkit: scroll the clip view, then tell the scroll view so the
// scroller knob follows.  The document view is FLIPPED, so px is measured from the top like every
// other coordinate the toolkit deals in — no flip arithmetic here.  Clamped to the document, because
// scrollToPoint: will happily leave the view showing blank space past the end.
void ux_ak_scroll_set(int handle, int node, int px)
    {
    if (node < 0 || node >= 256)
        return;
    NSScrollView* nsv = (NSScrollView*)g_ctl[handle][node];
    if (![nsv isKindOfClass:[NSScrollView class]])
        return;
    NSClipView* clip = [nsv contentView];
    CGFloat maxY = [[nsv documentView] frame].size.height - [clip bounds].size.height;
    if (maxY < 0)
        maxY = 0;
    CGFloat y = px < 0 ? 0 : (px > maxY ? maxY : px);
    [clip scrollToPoint:NSMakePoint([clip bounds].origin.x, y)];
    [nsv reflectScrolledClipView:clip];
    }
int ux_ak_scroll_get(int handle, int node)
    {
    if (node < 0 || node >= 256)
        return 0;
    NSScrollView* nsv = (NSScrollView*)g_ctl[handle][node];
    if (![nsv isKindOfClass:[NSScrollView class]])
        return 0;
    return (int)[[nsv contentView] bounds].origin.y;
    }

void ux_ak_scroll_reload(int handle, int node, int contentH)
    {
    if (node < 0 || node >= 256)
        return;
    NSScrollView* nsv = (NSScrollView*)g_ctl[handle][node];
    if (![nsv isKindOfClass:[NSScrollView class]])
        return;
    NSView* doc = [nsv documentView];
    NSRect f = [doc frame];
    NSSize cs = [nsv contentSize];
    f.size.width = cs.width;
    f.size.height = contentH > (int)cs.height ? contentH : (int)cs.height;
    [doc setFrame:f];
    [doc setNeedsDisplay:YES];
    }

// One modal drag-track step (a split-view divider, etc.): pull the next left-mouse dragged/up event.
// Returns window-local (g_view) coords + 1 while dragging, 0 once released.
int ux_ak_drag_next(int* x, int* y)
    {
    NSEvent* e = [NSApp nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)
                                    untilDate:[NSDate distantFuture]
                                       inMode:NSEventTrackingRunLoopMode
                                      dequeue:YES];
    if (!e || [e type] == NSEventTypeLeftMouseUp)
        return 0;
    NSWindow* w = [e window];
    int h = 0;
    for (int i = 1; i < UX_MAXW; i++)
        {
        if (g_win[i] == w)
            {
            h = i;
            break;
            }
        }
    NSView* v = (h && g_view[h]) ? g_view[h] : [w contentView];
    NSPoint p = [v convertPoint:[e locationInWindow] fromView:nil];
    if (x)
        *x = (int)p.x;
    if (y)
        *y = (int)p.y;
    return 1;
    }

// Dump the last headless render as a PPM.  A test can assert single pixels through ux_ak_pixel, but
// a DRAWING defect — a seam between two abutting polygons, a silhouette that wobbles by a pixel — is
// not a pixel, it is a shape, and the only honest way to check it is to look at the whole thing.
static int akWriteRepPPM(NSBitmapImageRep* rep, const char* path)
    {
    if (!rep)
        return 0;
    int w = (int)[rep pixelsWide], h = (int)[rep pixelsHigh];
    FILE* f = fopen(path, "wb");
    if (!f)
        return 0;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            {
            NSColor* c = [[rep colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
            // composite over white: an unpainted (transparent) ground must read
            // as paper, not black — the capture legs' shared convention
            CGFloat a = [c alphaComponent];
            unsigned char px[3] = {(unsigned char)(([c redComponent] * a + (1 - a)) * 255),
                                   (unsigned char)(([c greenComponent] * a + (1 - a)) * 255),
                                   (unsigned char)(([c blueComponent] * a + (1 - a)) * 255)};
            fwrite(px, 1, 3, f);
            }
    fclose(f);
    return 1;
    }
int ux_ak_dump_ppm(const char* path)
    {
    return akWriteRepPPM(g_lastRep, path);
    }

/* ---- portrait rigs (capture only) -----------------------------------------------------------
 * The alert portrait builds the SAME NSAlert ux_ak_alert builds, lays it out
 * without running it, and dumps the panel's content view.  The toolbar
 * portrait attaches a real NSToolbar to a window and dumps the THEME FRAME
 * (contentView.superview) — the view that owns titlebar + toolbar chrome —
 * so the portrait is the genuine article without a shown window. */
int ux_ak_alert_dump(int icon, const char* lines, const char* buttons, const char* path)
    {
    NSAlert* a = [[NSAlert alloc] init];
    [a setAlertStyle:(icon >= 3 ? NSAlertStyleCritical : NSAlertStyleInformational)];
    NSArray* ls = [[NSString stringWithUTF8String:lines] componentsSeparatedByString:@"|"];
    [a setMessageText:[ls count] > 0 ? ls[0] : @""];
    if ([ls count] > 1)
        {
        NSRange r = NSMakeRange(1, [ls count] - 1);
        [a setInformativeText:[[ls subarrayWithRange:r] componentsJoinedByString:@"\n"]];
        }
    NSArray* bs = [[NSString stringWithUTF8String:buttons] componentsSeparatedByString:@"|"];
    for (NSString* b in bs)
        [a addButtonWithTitle:b];
    [a layout];
    NSWindow* w = [a window];
    [w layoutIfNeeded];
    NSView* v = [w contentView];
    NSRect b = [v bounds];
    NSBitmapImageRep* rep = [v bitmapImageRepForCachingDisplayInRect:b];
    if (!rep)
        return 0;
    [v cacheDisplayInRect:b toBitmapImageRep:rep];
    return akWriteRepPPM(rep, path);
    }

@interface UXCapToolbarDelegate : NSObject <NSToolbarDelegate>
@end
@implementation UXCapToolbarDelegate
- (NSArray<NSToolbarItemIdentifier>*)toolbarAllowedItemIdentifiers:(NSToolbar*)tb
    {
    return @[ @"new", @"open", NSToolbarFlexibleSpaceItemIdentifier, @"find" ];
    }
- (NSArray<NSToolbarItemIdentifier>*)toolbarDefaultItemIdentifiers:(NSToolbar*)tb
    {
    return @[ @"new", @"open", NSToolbarFlexibleSpaceItemIdentifier, @"find" ];
    }
- (NSToolbarItem*)toolbar:(NSToolbar*)tb itemForItemIdentifier:(NSToolbarItemIdentifier)ident
    willBeInsertedIntoToolbar:(BOOL)flag
    {
    NSToolbarItem* it = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    NSString *label = ident, *sym = @"doc";
    if ([ident isEqualToString:@"new"])
        {
        label = @"New";
        sym = @"doc.badge.plus";
        }
    if ([ident isEqualToString:@"open"])
        {
        label = @"Open";
        sym = @"folder";
        }
    if ([ident isEqualToString:@"find"])
        {
        label = @"Find";
        sym = @"magnifyingglass";
        }
    [it setLabel:label];
    [it setImage:[NSImage imageWithSystemSymbolName:sym accessibilityDescription:label]];
    return it;
    }
@end
static UXCapToolbarDelegate* g_capTbDelegate;
int ux_ak_toolbar_dump(int w, int h, const char* path)
    {
    NSWindow* win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, w, h)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [win setTitle:@"Rocks"];
    [win setReleasedWhenClosed:NO];
    NSToolbar* tb = [[NSToolbar alloc] initWithIdentifier:@"ux-cap"];
    g_capTbDelegate = [UXCapToolbarDelegate new];
    [tb setDelegate:g_capTbDelegate];
    [tb setDisplayMode:NSToolbarDisplayModeIconAndLabel];
    [win setToolbar:tb];
    [win layoutIfNeeded];
    NSView* frame = [[win contentView] superview]; // the theme frame: titlebar + toolbar + content
    NSRect b = [frame bounds];
    NSBitmapImageRep* rep = [frame bitmapImageRepForCachingDisplayInRect:b];
    if (!rep)
        return 0;
    [frame cacheDisplayInRect:b toBitmapImageRep:rep];
    return akWriteRepPPM(rep, path);
    }

// ---- pixel readback (headless test verification) --------------------------------------------
int ux_ak_pixel(int handle, int x, int y)
    {
    if (!g_lastRep)
        return -1;
    NSColor* c = [g_lastRep colorAtX:x y:y];
    int R = (int)([c redComponent] * 255 + 0.5);
    int G = (int)([c greenComponent] * 255 + 0.5);
    int B = (int)([c blueComponent] * 255 + 0.5);
    return (R << 16) | (G << 8) | B;
    }
