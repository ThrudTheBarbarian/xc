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
#import <QuartzCore/QuartzCore.h> // CADisplayLink, for the turn
#include <mach/mach.h>
#include <sys/time.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <OpenGL/gl.h>
#include <OpenGL/OpenGL.h>      // CGL: CGLTexImageIOSurface2D, for the offscreen GL surface
#include <IOSurface/IOSurface.h> // the texture the GL renders into, drawn by the toolkit
#include "ux_posix_fs.h" // listDir / delete / rename / copy for the drawn file panel
#import <objc/runtime.h>

#define UX_MAXW 64
/* The toolkit's bytes as an NSString: UTF-8, or Latin-1 when they are not UTF-8 (a GEM resource's
 * strings are Latin-1), or "" for none.  AppKit raises on a nil string, so no conversion may
 * return one. */
static NSString* ak_ns(const char* s)
    {
    if (!s)
        return @"";
    NSString* u = [NSString stringWithUTF8String:s];
    if (u)
        return u;
    u = [NSString stringWithCString:s encoding:NSISOLatin1StringEncoding];
    return u ? u : @"";
    }
/* The nodes of one window's tree a native control can be made for.  A designer's window (Rocks:
 * outline, canvas, inspector, library) runs to several hundred. */
#define UX_MAXN 4096

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
/* The rep the LAST GL grab wrote, so a harness can ask what the picture holds instead
 * of trusting that the call returned.  A dump that is one flat colour is a blank dump,
 * which is the failure a spike of this kind produces. */
static NSBitmapImageRep* g_lastGrab = 0;
static int g_interactive = 0;
static int g_quit = 0;
static id g_winDelegate = 0;
static id g_menuTarget = 0;
static ux_dispatch_fn g_dispatch = 0;
/* A file dropped on a window: its path, the window, and the point in the window's content. */
typedef void (*ux_file_drop_fn)(const char* path, int win, int x, int y);
static ux_file_drop_fn g_fileDrop = 0;
/* A row dragged out of one of the app's tables, dropped on a window: its text, the window, the point. */
static ux_file_drop_fn g_itemDrop = 0;
/* The pasteboard type a table row travels as: private to the app. */
#define AK_ROW_TYPE @"org.xc.uxkit.row"
void ux_ak_set_item_drop(void* fn)
    {
    g_itemDrop = (ux_file_drop_fn)fn;
    }

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
/* An event's point for the toolkit: the content view's coordinates, as it shows on screen.  Over a
 * native scroll view's document, the toolkit adds the scroll offset in its own hit test
 * (UXWindow.hitScrolled), so a real click and a synthetic one agree. */
static NSPoint ak_tree_point(NSView* content, NSEvent* ev, int handle)
    {
    (void)handle;
    return [content convertPoint:[ev locationInWindow] fromView:nil];
    }
static void ak_mouseDown(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id ev)
    {
    if (!g_dispatch)
        return;
    int h = 0;
    for (int i = 1; i < UX_MAXW; i++)
        {
        if (g_view[i] == (NSView*)self)
            {
            h = i;
            break;
            }
        }
    NSPoint p = ak_tree_point((NSView*)self, (NSEvent*)ev, h);
    // A Control-click is the secondary button on macOS (the browser fires `contextmenu` for it), so
    // deliver it as UXEventRightMouseDown (16) -- a trackpad player has no other way to a menu.
    g_dispatch((([(NSEvent*)ev modifierFlags] & NSEventModifierFlagControl) != 0) ? 16 : 1,
               (int)p.x, (int)p.y, h); // route to the window that got the event, not always #1
    }
static void ak_keyDown(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id ev)
    {
    if (!g_dispatch)
        return;
    NSString* ch = [(NSEvent*)ev characters];
    g_dispatch(4, 0, 0, [ch length] > 0 ? (int)[ch characterAtIndex:0] : 0);
    }
/* The window a view belongs to, or 0 — the dispatch tags the event with it so the toolkit routes
 * to the window that got it rather than always to #1. */
static int ak_win_of(NSView* v)
    {
    for (int i = 1; i < UX_MAXW; i++)
        if (g_view[i] == v)
            return i;
    return 0;
    }
/* Pointer movement, the secondary button and the wheel go through the SAME dispatch as the press,
 * in the view's own (document) coordinates, so the toolkit hit-tests the point and routes it as it
 * would a click.  mouseMoved: only fires if the view has a tracking area with NSTrackingMouseMoved
 * (see ak_updateTrackingAreas).
 *
 * The dispatch word carries ONE extra value beside the point, and the wheel needs two — the window
 * it happened over, and how many notches.  So the wheel packs both into that word: the window in
 * the high bits, the (signed) notch count in the low byte.  The driver unpacks it; it is a private
 * encoding between this shim and xgAKDispatch, not part of the seam. */
#define AK_WHEEL_PACK(win, px) (((win) << 16) | ((px) & 0xFFFF))
static void ak_mouseMoved(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id ev)
    {
    if (!g_dispatch)
        return;
    NSPoint p = ak_tree_point((NSView*)self, (NSEvent*)ev, ak_win_of((NSView*)self));
    g_dispatch(15, (int)p.x, (int)p.y, ak_win_of((NSView*)self)); // 15 = UXEventMouseMoved
    }
static void ak_rightMouseDown(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id ev)
    {
    if (!g_dispatch)
        return;
    NSPoint p = ak_tree_point((NSView*)self, (NSEvent*)ev, ak_win_of((NSView*)self));
    g_dispatch(16, (int)p.x, (int)p.y, ak_win_of((NSView*)self)); // 16 = UXEventRightMouseDown
    }
static void ak_scrollWheel(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id ev)
    {
    if (!g_dispatch)
        return;
    NSPoint p = [(NSView*)self convertPoint:[(NSEvent*)ev locationInWindow] fromView:nil];
    /* PIXELS, the browser's contract.  A precise device (trackpad / Magic Mouse) reports pixels
     * already; a line-based wheel reports LINES, and one line steps 100px the way WebKit and Chrome
     * do, so a click zooms the map the ~17% the web client does rather than the ~1.6% a 10px notch
     * gave.  Passing the delta unrounded, as the browser does. */
    double dy = [(NSEvent*)ev scrollingDeltaY];
    int px = [(NSEvent*)ev hasPreciseScrollingDeltas] ? (int)dy : (int)(dy * 100.0);
    g_dispatch(11, (int)p.x, (int)p.y, AK_WHEEL_PACK(ak_win_of((NSView*)self), px)); // 11 = UXEventWheel
    }
/* A tracking area is what makes AppKit send mouseMoved: — without one the message is never
 * delivered, which is why the toolkit heard clicks and nothing else.  The rect is NSZeroRect with
 * NSTrackingInVisibleRect, so it always covers the view without being repositioned. */
static void ak_updateTrackingAreas(__unsafe_unretained id self, SEL _cmd)
    {
    for (NSTrackingArea* ta in [(NSView*)self trackingAreas])
        [(NSView*)self removeTrackingArea:ta];
    NSTrackingAreaOptions opt = NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited
        | NSTrackingActiveInKeyWindow | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect;
    NSTrackingArea* ta = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:opt
                                                       owner:self userInfo:nil];
    [(NSView*)self addTrackingArea:ta];
    }

/* Files dragged from the Finder: a window's content view takes them, and each dropped file's path
 * goes to the toolkit (ux_ak_set_file_drop).  Controls in the window are its subviews and do not
 * register, so a drop over one reaches the content view. */
static NSArray* ak_drop_urls(id info)
    {
    NSPasteboard* pb = [info draggingPasteboard];
    return [pb readObjectsForClasses:@[ [NSURL class] ]
                             options:@{ NSPasteboardURLReadingFileURLsOnlyKey : @YES }];
    }
static NSString* ak_drop_row(id info)
    {
    return [[info draggingPasteboard] stringForType:AK_ROW_TYPE];
    }
/* A row being dragged over a window: where it is now, or (-1, -1) once it has left. */
static ux_file_drop_fn g_itemHover = 0;
void ux_ak_set_item_hover(void* fn)
    {
    g_itemHover = (ux_file_drop_fn)fn;
    }
static void ak_hover(id self, id info, BOOL gone)
    {
    NSString* row = ak_drop_row(info);
    if (!row || !g_itemHover)
        return;
    NSPoint p = [(NSView*)self convertPoint:[info draggingLocation] fromView:nil];
    g_itemHover([row UTF8String], ak_win_of((NSView*)self), gone ? -1 : (int)p.x, gone ? -1 : (int)p.y);
    }
static NSUInteger ak_draggingUpdated(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id info)
    {
    if (g_itemDrop && ak_drop_row(info))
        {
        ak_hover(self, info, NO);
        return NSDragOperationCopy;
        }
    return (g_fileDrop && [ak_drop_urls(info) count] > 0) ? NSDragOperationCopy : NSDragOperationNone;
    }
static void ak_draggingExited(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id info)
    {
    if (info)
        ak_hover(self, info, YES);
    }
static NSUInteger ak_draggingEntered(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id info)
    {
    if (g_itemDrop && ak_drop_row(info))
        {
        ak_hover(self, info, NO);
        return NSDragOperationCopy;
        }
    return (g_fileDrop && [ak_drop_urls(info) count] > 0) ? NSDragOperationCopy : NSDragOperationNone;
    }
static int ak_win_of(NSView* v);
/* Deliver dropped files to the toolkit: what performDragOperation: does, and what a test calls. */
static int ak_deliver_files(NSView* v, NSArray* urls, NSPoint p)
    {
    if (!g_fileDrop || [urls count] == 0)
        return 0;
    int h = ak_win_of(v);
    for (NSURL* u in urls)
        if ([u isFileURL])
            g_fileDrop([[u path] fileSystemRepresentation], h, (int)p.x, (int)p.y);
    return 1;
    }
static BOOL ak_performDragOperation(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id info)
    {
    NSPoint p = [(NSView*)self convertPoint:[info draggingLocation] fromView:nil];
    NSString* row = ak_drop_row(info);
    if (row && g_itemDrop)
        {
        ak_hover(self, info, YES); /* the preview goes: the drop places the real thing */
        g_itemDrop([row UTF8String], ak_win_of((NSView*)self), (int)p.x, (int)p.y);
        return YES;
        }
    return ak_deliver_files((NSView*)self, ak_drop_urls(info), p) ? YES : NO;
    }
void ux_ak_set_file_drop(void* fn)
    {
    g_fileDrop = (ux_file_drop_fn)fn;
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
    class_addMethod(c, sel_registerName("mouseMoved:"), (IMP)ak_mouseMoved, "v@:@");
    class_addMethod(c, sel_registerName("rightMouseDown:"), (IMP)ak_rightMouseDown, "v@:@");
    class_addMethod(c, sel_registerName("scrollWheel:"), (IMP)ak_scrollWheel, "v@:@");
    class_addMethod(c, sel_registerName("updateTrackingAreas"), (IMP)ak_updateTrackingAreas, "v@:");
    class_addMethod(c, sel_registerName("draggingEntered:"), (IMP)ak_draggingEntered, "Q@:@");
    class_addMethod(c, sel_registerName("performDragOperation:"), (IMP)ak_performDragOperation, "B@:@");
    class_addMethod(c, sel_registerName("draggingUpdated:"), (IMP)ak_draggingUpdated, "Q@:@");
    class_addMethod(c, sel_registerName("draggingExited:"), (IMP)ak_draggingExited, "v@:@");
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
    g_dispatch((([(NSEvent*)ev modifierFlags] & NSEventModifierFlagControl) != 0) ? 16 : 1, (int)p.x, (int)p.y, h);
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

/* ── the GL surface ──────────────────────────────────────────────────────────
 * The drawable a GL view renders into: the one native view the toolkit makes for
 * a view it does not paint itself.
 *
 * It is a plain NSView with an NSOpenGLContext attached by setView:, and not an
 * NSOpenGLView, for one reason.  NSOpenGLView owns a draw cycle of its own --
 * drawRect:, reshape, and a display link if it is asked for one -- and the whole
 * point of this seam is that the DRIVER owns the present.  setView: gives a
 * context a surface and says nothing about when anything is drawn, so presentGL
 * is the only thing that ever swaps.
 *
 * Surface order is the default and it is the order the toolkit wants: a context
 * attached this way is composited with the window's other content by its place in
 * the view hierarchy, so a sibling that paints 2D lands OVER the map with neither
 * side asking, which is exactly the client's two-layer stack.  The surface is
 * therefore added at the BOTTOM of the content view's subviews.
 *
 * It takes presses, like the shield, and for the same reason: a real NSView under
 * the pointer is where AppKit routes a click, and the map needs those clicks.
 * They are converted into the CONTENT view's coordinates, the space the toolkit
 * hit-tests in.
 *
 * Keyed by the NEUTRAL view pointer, because that is the only name the two sides
 * share -- the driver is handed a view and nothing else.  A handful per app, so
 * parallel arrays and a linear scan, like the shield. */
#define UX_AK_MAXGL 8
static void* g_glPeer[UX_AK_MAXGL];              // the neutral view (xtc object), the key
static NSView* g_glView[UX_AK_MAXGL];            // ARC-strong: assignment retains, = nil releases
static NSOpenGLContext* g_glCtx[UX_AK_MAXGL];    // ARC-strong
static NSOpenGLPixelFormat* g_glPf[UX_AK_MAXGL]; // ARC-strong: the context is made from it on request
static int g_glWin[UX_AK_MAXGL];
/* THE OFFSCREEN SURFACE (the one-surface decision, 2026-10-01).  The GL never draws to the
 * window.  It renders into a 4x multisampled framebuffer of its own, which presentGL resolves into
 * an IOSurface-backed texture; the toolkit then DRAWS that surface as an image in the window's one
 * 2-D pass, in tree order, with the ink and the panels painted over it like anything else.  There
 * is no GL plane for the compositor to order, tile or leave stale -- the shaded-rectangle reports
 * were exactly that -- and the map and the 2-D layer cannot disagree about a frame. */
static IOSurfaceRef g_glSurf[UX_AK_MAXGL]; // the resolved frame, read by the 2-D blit
static unsigned g_glTex[UX_AK_MAXGL];      // a GL_TEXTURE_RECTANGLE over g_glSurf
static unsigned g_glFbo[UX_AK_MAXGL];      // resolve target: g_glTex
static unsigned g_glMsFbo[UX_AK_MAXGL];    // render target: 4x MSAA (0 = render into g_glFbo)
static unsigned g_glMsRb[UX_AK_MAXGL];
static int g_glW[UX_AK_MAXGL];             // pixels
static int g_glH[UX_AK_MAXGL];
static int g_glCount = 0;
static Class g_glClass = 0;
static int g_glSwapInterval = 1; // 1 = the swap waits for the display; see ux_ak_gl_vsync

static int ak_gl_find(void* peer)
    {
    for (int i = 0; i < g_glCount; i++)
        {
        if (g_glPeer[i] == peer)
            return i;
        }
    return -1;
    }

static int ak_gl_win_of(NSView* v)
    {
    for (int i = 0; i < g_glCount; i++)
        if (g_glView[i] == v)
            return g_glWin[i];
    return 0;
    }
static void ak_glMouseDown(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id ev)
    {
    if (!g_dispatch)
        return;
    int h = ak_gl_win_of((NSView*)self);
    if (!h || !g_view[h])
        return;
    NSPoint p = [g_view[h] convertPoint:[(NSEvent*)ev locationInWindow] fromView:nil];
    g_dispatch((([(NSEvent*)ev modifierFlags] & NSEventModifierFlagControl) != 0) ? 16 : 1, (int)p.x, (int)p.y, h);
    }
/* The map's own surface hears move / right-click / wheel too, in the same coordinates the press
 * uses, so hit-testing the point lands on the GL view like any other. */
static void ak_glMouseMoved(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id ev)
    {
    if (!g_dispatch)
        return;
    int h = ak_gl_win_of((NSView*)self);
    if (!h || !g_view[h])
        return;
    NSPoint p = [g_view[h] convertPoint:[(NSEvent*)ev locationInWindow] fromView:nil];
    g_dispatch(15, (int)p.x, (int)p.y, h);
    }
static void ak_glRightMouseDown(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id ev)
    {
    if (!g_dispatch)
        return;
    int h = ak_gl_win_of((NSView*)self);
    if (!h || !g_view[h])
        return;
    NSPoint p = [g_view[h] convertPoint:[(NSEvent*)ev locationInWindow] fromView:nil];
    g_dispatch(16, (int)p.x, (int)p.y, h);
    }
static void ak_glScrollWheel(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id ev)
    {
    if (!g_dispatch)
        return;
    int h = ak_gl_win_of((NSView*)self);
    if (!h || !g_view[h])
        return;
    NSPoint p = [g_view[h] convertPoint:[(NSEvent*)ev locationInWindow] fromView:nil];
    double dy = [(NSEvent*)ev scrollingDeltaY];
    int px = [(NSEvent*)ev hasPreciseScrollingDeltas] ? (int)dy : (int)(dy * 100.0);
    g_dispatch(11, (int)p.x, (int)p.y, AK_WHEEL_PACK(h, px));
    }

static Class ak_gl_class(void)
    {
    if (g_glClass)
        return g_glClass;
    Class c = objc_allocateClassPair([NSView class], "UXGLSurface", 0);
    class_addMethod(c, sel_registerName("isFlipped"), (IMP)ak_isFlipped, "B@:");
    class_addMethod(c, sel_registerName("acceptsFirstMouse:"), (IMP)ak_acceptsFirstMouse, "B@:@");
    class_addMethod(c, sel_registerName("mouseDown:"), (IMP)ak_glMouseDown, "v@:@");
    class_addMethod(c, sel_registerName("mouseMoved:"), (IMP)ak_glMouseMoved, "v@:@");
    class_addMethod(c, sel_registerName("rightMouseDown:"), (IMP)ak_glRightMouseDown, "v@:@");
    class_addMethod(c, sel_registerName("scrollWheel:"), (IMP)ak_glScrollWheel, "v@:@");
    class_addMethod(c, sel_registerName("updateTrackingAreas"), (IMP)ak_updateTrackingAreas, "v@:");
    objc_registerClassPair(c);
    g_glClass = c;
    return c;
    }

/* Which GL, the answer a renderer loads its entry points from.  These mirror the
 * UX_GL_* values in UXViewDriver.xc and are ABI.  macOS offers a 3.2 or a 4.1
 * CORE profile and both are the same call set, so the answer is GL33: a version
 * number would be a second, redundant answer that another backend could not give. */
int ux_ak_gl_kind(void)
    {
    return 2; /* UX_GL_GL33 */
    }

/* An entry point by name, for the renderer.  On Apple the framework's symbols are in the
 * process already -- the link line is the loader -- so this is a lookup among the loaded
 * images and not a library the driver has to open.  It is here rather than in the renderer
 * because "how" is a property of the platform, and the renderer is the file that must not
 * know which platform it is on. */
void* ux_ak_gl_proc(const char* name)
    {
    if (!name)
        return 0;
    return dlsym(RTLD_DEFAULT, name);
    }

/* Make (or move) the SURFACE.  No context here: a view that never asks for one
 * costs nothing, which is what keeps a software-only run of a GL app identical to
 * a plain one.
 *
 * A HEADLESS GL CLIENT REACHES THIS ONLY VIA ux_ak_set_capture(1): realizeTree
 * builds no native view at all in a plain non-interactive run, so without the
 * capture switch there is no surface for ux_ak_gl_make to bind and a GL view
 * fails as if the backend had no GL.  Capture mode realises WITHOUT showing,
 * which is what a headless GL client wants and what the portrait pipeline uses
 * it for; set it before boot. */
void ux_ak_gl_place(int handle, void* peer, int x, int y, int w, int h, int hidden)
    {
    NSView* content = g_view[handle];
    if (!content || !peer)
        return;
    int i = ak_gl_find(peer);
    if (i >= 0)
        {
        [g_glView[i] setFrame:NSMakeRect(x, y, w, h)];
        [g_glView[i] setHidden:hidden ? YES : NO];
        return;
        }
    if (hidden)
        return; /* nothing to hide yet, and the surface is made on demand */
    if (g_glCount >= UX_AK_MAXGL)
        return;
    /* A 4x multisample buffer, so hexagon edges antialias the way the browser's
     * context does (client/gl.js asks for `antialias: true`).  The whole of the
     * residual difference between the two frames was a faint honeycomb where
     * hexagons meet, and this is it.  A pixel format that cannot give sample
     * buffers falls back to none rather than failing -- the surface matters more
     * than its edges. */
    NSOpenGLPixelFormatAttribute attrs[] =
        {
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
        NSOpenGLPFAColorSize, 24,
        NSOpenGLPFAAlphaSize, 8,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFASampleBuffers, 1,
        NSOpenGLPFASamples, 4,
        0
        };
    NSOpenGLPixelFormat* pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    if (!pf)
        {
        NSOpenGLPixelFormatAttribute plain[] =
            {
            NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
            NSOpenGLPFAColorSize, 24,
            NSOpenGLPFAAlphaSize, 8,
            NSOpenGLPFADoubleBuffer,
            NSOpenGLPFAAccelerated,
            0
            };
        pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:plain];
        }
    if (!pf)
        return;
    NSView* v = [[ak_gl_class() alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [v setWantsBestResolutionOpenGLSurface:YES];
    /* This view DRAWS NOTHING: the frame is rendered offscreen and painted by the toolkit in its 2-D
     * pass (the offscreen surface, above).  It is here for the input -- presses, hover, the wheel and
     * the right button on the map arrive on it -- and as the frame the driver sizes the surface to. */
    g_glPeer[g_glCount] = peer;
    g_glView[g_glCount] = v;
    g_glCtx[g_glCount] = nil;
    g_glPf[g_glCount] = pf;
    g_glWin[g_glCount] = handle;
    g_glCount = g_glCount + 1;
    /* BELOW every sibling: the map is the bottom of the stack, and a 2D view
     * painted over it has to land over it. */
    [content addSubview:v positioned:NSWindowBelow relativeTo:nil];
    }

/* The VIEWPORT is the driver's.  It is the drawable's size in PIXELS, and the
 * driver is the only side that knows it -- the view's frame is in points and the
 * two differ by the backing scale.  Set when the context is made and reset when
 * the surface is resized, both times in the same turn as the drawable itself, so a
 * renderer never has to set it and never has to ask what it is. */
static void ak_gl_viewport(int i)
    {
    // The drawable's own size: what ak_gl_size_px chose, the GPU's limit applied.
    glViewport(0, 0, g_glW[i] > 0 ? g_glW[i] : 1, g_glH[i] > 0 ? g_glH[i] : 1);
    }

/* Bind a context to the surface.  The token returned is an opaque handle and NOT
 * the NSOpenGLContext: the renderer hands it straight back and never reads
 * through it, and a small integer cannot be dereferenced by accident.  The
 * context is left CURRENT on the calling thread, which is the contract the seam
 * states -- a renderer that is handed a context it must make current itself would
 * have to know it is on AppKit. */
/* IOSurface, reached at RUN TIME.  Linking it would add -framework IOSurface to every build of this
 * shim -- the toolkit's gates and every client's -- for four calls; dlsym keeps the link line exactly
 * what it was.  The keys are the strings the kIOSurface* constants hold. */
static struct
    {
    int tried;
    IOSurfaceRef (*create)(CFDictionaryRef);
    void* (*base)(IOSurfaceRef);
    size_t (*rowBytes)(IOSurfaceRef);
    size_t (*width)(IOSurfaceRef);
    size_t (*height)(IOSurfaceRef);
    size_t (*allocSize)(IOSurfaceRef);
    kern_return_t (*lock)(IOSurfaceRef, uint32_t, uint32_t*);
    kern_return_t (*unlock)(IOSurfaceRef, uint32_t, uint32_t*);
    } g_ios;
static int ak_ios_load(void)
    {
    if (g_ios.tried)
        return g_ios.create != NULL;
    g_ios.tried = 1;
    void* h = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
    if (!h)
        return 0;
    g_ios.create = dlsym(h, "IOSurfaceCreate");
    g_ios.base = dlsym(h, "IOSurfaceGetBaseAddress");
    g_ios.rowBytes = dlsym(h, "IOSurfaceGetBytesPerRow");
    g_ios.width = dlsym(h, "IOSurfaceGetWidth");
    g_ios.height = dlsym(h, "IOSurfaceGetHeight");
    g_ios.allocSize = dlsym(h, "IOSurfaceGetAllocSize");
    g_ios.lock = dlsym(h, "IOSurfaceLock");
    g_ios.unlock = dlsym(h, "IOSurfaceUnlock");
    if (!g_ios.base || !g_ios.rowBytes || !g_ios.width || !g_ios.height || !g_ios.allocSize
        || !g_ios.lock || !g_ios.unlock)
        g_ios.create = NULL;
    return g_ios.create != NULL;
    }
/* ---- the offscreen surface (one-surface decision) -------------------------------------------- */
static void ak_gl_free_offscreen(int i)
    {
    if (g_glMsFbo[i])
        {
        glDeleteFramebuffers(1, &g_glMsFbo[i]);
        g_glMsFbo[i] = 0;
        }
    if (g_glMsRb[i])
        {
        glDeleteRenderbuffers(1, &g_glMsRb[i]);
        g_glMsRb[i] = 0;
        }
    if (g_glFbo[i])
        {
        glDeleteFramebuffers(1, &g_glFbo[i]);
        g_glFbo[i] = 0;
        }
    if (g_glTex[i])
        {
        glDeleteTextures(1, &g_glTex[i]);
        g_glTex[i] = 0;
        }
    if (g_glSurf[i])
        {
        CFRelease(g_glSurf[i]);
        g_glSurf[i] = NULL;
        }
    g_glW[i] = 0;
    g_glH[i] = 0;
    }
/* The framebuffer the renderer draws into: the multisampled one when there is one. */
static unsigned ak_gl_target(int i)
    {
    return g_glMsFbo[i] ? g_glMsFbo[i] : g_glFbo[i];
    }
/* Make (or remake at `w`x`h` PIXELS) the offscreen surface, and leave the render target bound, so
 * the renderer's default framebuffer IS it and it never has to know.
 *
 * The resolve texture is a RECTANGLE texture because that is the only target an IOSurface binds to
 * (CGLTexImageIOSurface2D answers kCGLBadValue for GL_TEXTURE_2D), and the IOSurface is the point:
 * the 2-D blit reads that same memory, so a frame reaches the window with no glReadPixels copy. */
static int ak_gl_alloc_offscreen(int i, int w, int h)
    {
    if (w <= 0 || h <= 0)
        return 0;
    if (g_glFbo[i] && g_glW[i] == w && g_glH[i] == h)
        {
        glBindFramebuffer(GL_FRAMEBUFFER, ak_gl_target(i));
        return 1;
        }
    ak_gl_free_offscreen(i);
    if (!ak_ios_load())
        {
        fprintf(stderr, "gl: IOSurface is not available\n");
        return 0;
        }
    NSDictionary* props = @{ @"IOSurfaceWidth" : @(w), @"IOSurfaceHeight" : @(h),
                             @"IOSurfaceBytesPerElement" : @(4),
                             @"IOSurfacePixelFormat" : @((unsigned)'BGRA') };
    IOSurfaceRef surf = g_ios.create((__bridge CFDictionaryRef)props);
    if (!surf)
        {
        fprintf(stderr, "gl: IOSurfaceCreate %dx%d failed\n", w, h);
        return 0;
        }
    GLuint tex = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, tex);
    CGLError ce = CGLTexImageIOSurface2D(CGLGetCurrentContext(), GL_TEXTURE_RECTANGLE_ARB, GL_RGBA,
                                         w, h, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, surf, 0);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);
    if (ce != kCGLNoError)
        {
        fprintf(stderr, "gl: CGLTexImageIOSurface2D failed (%d)\n", (int)ce);
        glDeleteTextures(1, &tex);
        CFRelease(surf);
        return 0;
        }
    GLuint fbo = 0;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE_ARB, tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        {
        fprintf(stderr, "gl: resolve framebuffer incomplete\n");
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glDeleteFramebuffers(1, &fbo);
        glDeleteTextures(1, &tex);
        CFRelease(surf);
        return 0;
        }
    g_glSurf[i] = surf;
    g_glTex[i] = tex;
    g_glFbo[i] = fbo;
    g_glW[i] = w;
    g_glH[i] = h;
    /* The RENDER target is 4x multisampled, so hexagon edges antialias as the window drawable's
     * did (and as the browser's context does).  A context that cannot is not a failure: the
     * renderer draws straight into the resolve framebuffer and the edges are aliased. */
    GLint maxs = 0;
    glGetIntegerv(GL_MAX_SAMPLES, &maxs);
    if (maxs >= 2)
        {
        GLuint rb = 0;
        GLuint ms = 0;
        glGenRenderbuffers(1, &rb);
        glBindRenderbuffer(GL_RENDERBUFFER, rb);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, maxs >= 4 ? 4 : maxs, GL_RGBA8, w, h);
        glBindRenderbuffer(GL_RENDERBUFFER, 0);
        glGenFramebuffers(1, &ms);
        glBindFramebuffer(GL_FRAMEBUFFER, ms);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE)
            {
            g_glMsRb[i] = rb;
            g_glMsFbo[i] = ms;
            }
        else
            {
            glDeleteFramebuffers(1, &ms);
            glDeleteRenderbuffers(1, &rb);
            }
        }
    glBindFramebuffer(GL_FRAMEBUFFER, ak_gl_target(i));
    return 1;
    }
/* The largest surface this context can render: a texture (the resolve target), a renderbuffer (the
 * multisampled one) and a viewport must all hold it.  0 = no context current.  A test can lower it
 * (ux_ak_gl_test_max) to exercise the clamp on a GPU whose real limit is far above any window. */
static int g_glTestMax = 0;
static int ak_gl_max_px(void)
    {
    if (!CGLGetCurrentContext())
        return 0;
    GLint tex = 0, rb = 0, vp[2] = {0, 0};
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &tex);
    glGetIntegerv(GL_MAX_RENDERBUFFER_SIZE, &rb);
    glGetIntegerv(GL_MAX_VIEWPORT_DIMS, vp);
    int m = tex;
    if (rb > 0 && rb < m)
        m = rb;
    if (vp[0] > 0 && vp[0] < m)
        m = vp[0];
    if (vp[1] > 0 && vp[1] < m)
        m = vp[1];
    if (g_glTestMax > 0 && (m <= 0 || g_glTestMax < m))
        m = g_glTestMax;
    return m;
    }
void ux_ak_gl_test_max(int px)
    {
    g_glTestMax = px;
    }
/* Test only: clear a GL view's drawable to one colour (0xRRGGBB), the frame a renderer would draw. */
void ux_ak_gl_test_fill(void* peer, int rgb)
    {
    int i = ak_gl_find(peer);
    if (i < 0 || !g_glCtx[i])
        return;
    [g_glCtx[i] makeCurrentContext];
    glBindFramebuffer(GL_FRAMEBUFFER, ak_gl_target(i));
    glClearColor(((rgb >> 16) & 255) / 255.0f, ((rgb >> 8) & 255) / 255.0f, (rgb & 255) / 255.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    }
/* The drawable's size in PIXELS: the view's points at the backing scale, then -- if that is more than
 * the GPU can hold (a maximised window on a 5K display is ~5120 wide; an old integrated GPU stops at
 * 4096) -- scaled down by one factor on both sides, so the aspect is kept.  The 2-D pass draws the
 * frame into the view's rectangle in points, so a smaller surface is simply stretched to fit: softer,
 * never cropped, and the renderer is none the wiser (it reads no size; the viewport follows this). */
static void ak_gl_size_px(int i, int* pw, int* ph)
    {
    NSRect b = [g_glView[i] bounds];
    float scale = [[g_glView[i] window] backingScaleFactor];
    if (scale <= 0)
        scale = 1;
    double w = b.size.width * scale;
    double h = b.size.height * scale;
    int m = ak_gl_max_px();
    if (m > 0 && (w > m || h > m))
        {
        double k = (w > h ? m / w : m / h);
        w = w * k;
        h = h * k;
        }
    *pw = (int)w;
    *ph = (int)h;
    if (*pw < 1)
        *pw = 1;
    if (*ph < 1)
        *ph = 1;
    }

void* ux_ak_gl_make(void* peer)
    {
    int i = ak_gl_find(peer);
    if (i < 0)
        return 0;
    if (!g_glCtx[i])
        {
        NSOpenGLContext* c = [[NSOpenGLContext alloc] initWithFormat:g_glPf[i] shareContext:nil];
        if (!c)
            return 0;
        /* NO setView: -- the context never draws to the window; see the offscreen surface. */
        g_glCtx[i] = c;
        }
    [g_glCtx[i] makeCurrentContext];
    int pw = 0;
    int ph = 0;
    ak_gl_size_px(i, &pw, &ph);
    if (!ak_gl_alloc_offscreen(i, pw, ph))
        return 0;
    ak_gl_viewport(i);
    return (void*)(long)(i + 1);
    }

void ux_ak_gl_resize(void* peer, int w, int h)
    {
    int i = ak_gl_find(peer);
    if (i < 0)
        return;
    NSRect f = [g_glView[i] frame];
    [g_glView[i] setFrame:NSMakeRect(f.origin.x, f.origin.y, w, h)];
    if (g_glCtx[i])
        {
        [g_glCtx[i] makeCurrentContext];
        int pw = 0;
        int ph = 0;
        ak_gl_size_px(i, &pw, &ph);
        ak_gl_alloc_offscreen(i, pw, ph);
        ak_gl_viewport(i);
        }
    }

/* The frame is finished.  There is no swap: the multisampled target is resolved into the
 * IOSurface, the GPU is waited for (the 2-D blit reads that memory on the CPU), and the part of the
 * window the GL view covers is marked dirty, so the toolkit draws the new frame in its next 2-D
 * pass -- the one present the driver owns, at most once a turn. */
void ux_ak_gl_present(void* peer)
    {
    int i = ak_gl_find(peer);
    if (i < 0 || !g_glCtx[i] || !g_glFbo[i])
        return;
    [g_glCtx[i] makeCurrentContext];
    if (g_glMsFbo[i])
        {
        glBindFramebuffer(GL_READ_FRAMEBUFFER, g_glMsFbo[i]);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g_glFbo[i]);
        glBlitFramebuffer(0, 0, g_glW[i], g_glH[i], 0, 0, g_glW[i], g_glH[i], GL_COLOR_BUFFER_BIT,
                          GL_NEAREST);
        }
    glBindFramebuffer(GL_FRAMEBUFFER, ak_gl_target(i)); // the renderer's again, for the next frame
    glFinish();
    /* The drawable follows the BACKING SCALE.  A window dragged from a 1x display to a 2x one keeps
     * its size in points and doubles in pixels, and nothing resizes it, so the frame would go on
     * rendering at half resolution.  Checked once a frame: the NEXT frame renders at the new size
     * (this one is already drawn), at the cost of one empty frame when the scale changes. */
    int pw = 0;
    int ph = 0;
    ak_gl_size_px(i, &pw, &ph);
    if (pw > 0 && ph > 0 && (pw != g_glW[i] || ph != g_glH[i]))
        {
        ak_gl_alloc_offscreen(i, pw, ph);
        ak_gl_viewport(i);
        }
    NSView* dv = g_glWin[i] > 0 ? g_view[g_glWin[i]] : nil;
    if (dv && ![g_glView[i] isHidden])
        [dv setNeedsDisplayInRect:[g_glView[i] frame]];
    }

/* Draw a GL view's last presented frame into the CURRENT 2-D context at (x,y,w,h), the toolkit's
 * coordinates.  1 when it drew; 0 when there is no frame (no GL on this run, or no context yet), so
 * the caller falls back to the view's drawRect.
 *
 * No flip: the surface's rows are GL's, bottom-up, and the toolkit's context is FLIPPED (y down), so
 * an image drawn straight into it lands the right way up -- the two inversions cancel.  Opaque on
 * purpose (the alpha is skipped), as the window drawable was: the map is the bottom of the stack. */
int ux_ak_gl_draw_view(void* peer, int x, int y, int w, int h)
    {
    int i = ak_gl_find(peer);
    if (i < 0 || !g_glSurf[i] || w <= 0 || h <= 0)
        return 0;
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx)
        return 0;
    IOSurfaceRef s = g_glSurf[i];
    g_ios.lock(s, 1u /* kIOSurfaceLockReadOnly */, NULL);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, g_ios.base(s),
                                                        g_ios.allocSize(s), NULL);
    CGImageRef img = CGImageCreate(g_ios.width(s), g_ios.height(s), 8, 32,
                                   g_ios.rowBytes(s), cs,
                                   kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, dp, NULL,
                                   false, kCGRenderingIntentDefault);
    if (img)
        CGContextDrawImage(ctx, CGRectMake(x, y, w, h), img);
    CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    g_ios.unlock(s, 1u /* kIOSurfaceLockReadOnly */, NULL);
    return img ? 1 : 0;
    }

/* How hard the swap blocks.  A map app wants 1; a frame-time measurement wants 0,
 * because with a blocking swap the number is the refresh rate.  Applied to the
 * surfaces that already exist and to any made later, so the order of the two calls
 * does not matter. */
void ux_ak_gl_vsync(int interval)
    {
    g_glSwapInterval = interval;
    GLint v = (GLint)(interval > 0 ? 1 : 0);
    for (int i = 0; i < g_glCount; i++)
        {
        if (g_glCtx[i])
            [g_glCtx[i] setValues:&v forParameter:NSOpenGLCPSwapInterval];
        }
    }

/* The last PRESENTED frame, as a PNG.  The resolved surface is exactly what the toolkit draws in
 * the window, so this is the picture of "what the map was" -- and the window grab beside it shows
 * that it reached the window, with the 2-D layer over it.  Rows are flipped to top-down, because
 * the whole point is that somebody LOOKS at it. */
int ux_ak_gl_grab(void* peer, const char* path)
    {
    int i = ak_gl_find(peer);
    if (i < 0 || !g_glSurf[i])
        return 0;
    IOSurfaceRef s = g_glSurf[i];
    int pw = (int)g_ios.width(s);
    int ph = (int)g_ios.height(s);
    size_t stride = g_ios.rowBytes(s);
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:pw pixelsHigh:ph bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:pw * 4 bitsPerPixel:32];
    if (!rep || ![rep bitmapData])
        return 0;
    unsigned char* dst = [rep bitmapData];
    g_ios.lock(s, 1u /* kIOSurfaceLockReadOnly */, NULL);
    const unsigned char* src = (const unsigned char*)g_ios.base(s);
    for (int y = 0; y < ph; y++)
        {
        const unsigned char* r = src + (size_t)(ph - 1 - y) * stride; // bottom-up -> top-down
        unsigned char* d = dst + (size_t)y * pw * 4;
        for (int x = 0; x < pw; x++)
            {
            d[x * 4 + 0] = r[x * 4 + 2]; // BGRA -> RGBA
            d[x * 4 + 1] = r[x * 4 + 1];
            d[x * 4 + 2] = r[x * 4 + 0];
            d[x * 4 + 3] = 255;
            }
        }
    g_ios.unlock(s, 1u /* kIOSurfaceLockReadOnly */, NULL);
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    int ok = png && [png writeToFile:ak_ns(path) atomically:YES];
    if (ok)
        g_lastGrab = rep;
    return ok ? 1 : 0;
    }

/* The colour at (x,y) of the last grab, as 0xRRGGBB, or -1 off the picture.  A gate that has to
 * say WHICH thing is on top at a point -- the ink, or the map under it -- needs a colour, not a
 * count of marks. */
int ux_ak_gl_grab_pixel(int x, int y)
    {
    if (!g_lastGrab || x < 0 || y < 0 || x >= [g_lastGrab pixelsWide] || y >= [g_lastGrab pixelsHigh])
        return -1;
    NSColor* c = [[g_lastGrab colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    int r = (int)([c redComponent] * 255.0 + 0.5);
    int g = (int)([c greenComponent] * 255.0 + 0.5);
    int b = (int)([c blueComponent] * 255.0 + 0.5);
    return (r << 16) | (g << 8) | b;
    }

/* How many pixels in the last GL grab differ from its top-left pixel, sampling every
 * 2nd pixel.  A blank dump reads 0; a map or a line of text reads many.  Distinct-colour
 * counting is not enough here: a thin line of text on white is dozens of greys but a
 * 16-pixel stride can walk straight between the glyph strokes and find none. */
int ux_ak_gl_grab_marks(void)
    {
    if (!g_lastGrab)
        return 0;
    NSInteger pw = [g_lastGrab pixelsWide];
    NSInteger ph = [g_lastGrab pixelsHigh];
    if (pw <= 0 || ph <= 0)
        return 0;
    NSColor* bg = [g_lastGrab colorAtX:0 y:0];
    int br = (int)([bg redComponent] * 255.0 + 0.5);
    int bgc = (int)([bg greenComponent] * 255.0 + 0.5);
    int bb = (int)([bg blueComponent] * 255.0 + 0.5);
    int marks = 0;
    for (NSInteger y = 0; y < ph; y += 2)
        {
        for (NSInteger x = 0; x < pw; x += 2)
            {
            NSColor* c = [g_lastGrab colorAtX:x y:y];
            if (!c)
                continue;
            int R = (int)([c redComponent] * 255.0 + 0.5);
            int G = (int)([c greenComponent] * 255.0 + 0.5);
            int B = (int)([c blueComponent] * 255.0 + 0.5);
            if (R != br || G != bgc || B != bb)
                marks = marks + 1;
            }
        }
    return marks;
    }

/* The drawable's size in pixels and the view's size in points, so a harness can
 * STATE the ratio it measured at instead of assuming one.  Fills out4 with
 * { pointW, pointH, pixelW, pixelH } and returns 1. */
/* How many samples the context's framebuffer actually carries.  4 when the multisample
 * pixel format was accepted, 0 when it fell back to none; asking the GL itself is the only
 * way to know which, since initWithAttributes: succeeds for either. */
int ux_ak_gl_samples(void* peer)
    {
    int i = ak_gl_find(peer);
    if (i < 0 || !g_glCtx[i])
        return 0;
    NSOpenGLContext* prev = [NSOpenGLContext currentContext];
    [g_glCtx[i] makeCurrentContext];
    GLint s = 0;
    glGetIntegerv(GL_SAMPLES, &s);
    if (prev)
        [prev makeCurrentContext];
    else
        [NSOpenGLContext clearCurrentContext];
    return (int)s;
    }

/* The offscreen surface's size in PIXELS, as it is now -- what the renderer is drawing into.  A test
 * compares it with ux_ak_gl_backing to see that the drawable followed the backing scale. */
int ux_ak_gl_surface_size(void* peer, int* out2)
    {
    int i = ak_gl_find(peer);
    if (i < 0 || !g_glFbo[i])
        return 0;
    out2[0] = g_glW[i];
    out2[1] = g_glH[i];
    return 1;
    }
/* Move a window onto the first screen whose backing scale is `scale` (2 = a Retina display), so a
 * gate can exercise a change of backing scale on a machine that has both.  0 = no such screen. */
int ux_ak_window_to_scale(int handle, int scale)
    {
    NSWindow* w = (handle > 0 && handle < UX_MAXW) ? g_win[handle] : nil;
    if (!w)
        return 0;
    for (NSScreen* sc in [NSScreen screens])
        {
        if ((int)[sc backingScaleFactor] == scale)
            {
            NSRect vf = [sc visibleFrame];
            [w setFrameTopLeftPoint:NSMakePoint(vf.origin.x + 40, vf.origin.y + vf.size.height - 40)];
            return 1;
            }
        }
    return 0;
    }

/* The last frame, out of the IOSurface the view renders into (which keeps it), top row first, as
 * 0xAARRGGBB -- ux_ak_gl_grab's read, into memory instead of a PNG file. */
int ux_ak_gl_read(void* peer, unsigned* out, int pw, int ph)
    {
    int i = ak_gl_find(peer);
    if (i < 0 || !g_glSurf[i])
        return 0;
    IOSurfaceRef s = g_glSurf[i];
    if ((int)g_ios.width(s) != pw || (int)g_ios.height(s) != ph)
        return 0;
    size_t stride = g_ios.rowBytes(s);
    g_ios.lock(s, 1u /* kIOSurfaceLockReadOnly */, NULL);
    const unsigned char* src = (const unsigned char*)g_ios.base(s);
    for (int y = 0; y < ph; y++)
        {
        const unsigned char* r = src + (size_t)(ph - 1 - y) * stride; /* bottom-up -> top-down */
        for (int x = 0; x < pw; x++)
            out[(size_t)y * pw + x] = ((unsigned)r[x * 4 + 3] << 24) | ((unsigned)r[x * 4 + 2] << 16) |
                                       ((unsigned)r[x * 4 + 1] << 8) | r[x * 4 + 0]; /* BGRA */
        }
    g_ios.unlock(s, 1u, NULL);
    return 1;
    }
int ux_ak_gl_backing(void* peer, int* out4)
    {
    int i = ak_gl_find(peer);
    if (i < 0 || !g_glView[i])
        return 0;
    NSRect b = [g_glView[i] bounds];
    float scale = [[g_glView[i] window] backingScaleFactor];
    if (scale <= 0)
        scale = 1;
    out4[0] = (int)b.size.width;
    out4[1] = (int)b.size.height;
    out4[2] = (int)(b.size.width * scale);
    out4[3] = (int)(b.size.height * scale);
    return 1;
    }

/* Draw the view that holds the tree -- the UXDrawView, which is where the GL surface
 * and the native label overlays live -- into a PNG.  `peer` is the same token the GL
 * calls take -- the neutral view, not the surface.
 *
 * The sibling of ux_ak_gl_grab and NOT a replacement for it: the front-buffer read
 * shows what the SURFACE got, and this shows what the toolkit's own view tree holds --
 * the 2D views, their text and their order.  The GL surface draws its software fallback
 * here (drawRect), because a composited surface is not part of the bitmap AppKit
 * renders, so this picture shows the overlay and not the map.  Two dumps on purpose:
 * which of the two holds what is the answer to where the drawing went.
 *
 * The window's own background is not painted by the toolkit, so the bitmap is filled
 * white first; without it the labels draw dark-on-black and the dump reads as empty. */
int ux_ak_gl_grab_window(void* peer, const char* path)
    {
    int i = ak_gl_find(peer);
    if (i < 0 || !g_glView[i])
        return 0;
    /* The WINDOW'S content view, so the picture holds everything: the toolkit's draw view (inside an
     * NSScrollView) AND any overlay surface, which lives on the content view ABOVE the scroll clip.
     * Grabbing only the draw view would miss the surface. */
    NSView* content = [g_glView[i] window] != nil ? [[g_glView[i] window] contentView] : [g_glView[i] superview];
    if (!content)
        return 0;
    NSRect b = [content bounds];
    int w = (int)b.size.width;
    int h = (int)b.size.height;
    if (w <= 0 || h <= 0)
        return 0;
    /* A window has a background the toolkit does not paint, so the bitmap starts as
     * the window's own colour.  Without this the labels draw dark-on-black and the
     * dump looks empty when it is not. */
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32];
    if (!rep)
        return 0;
    NSGraphicsContext* gctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (!gctx)
        return 0;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:gctx];
    [[NSColor whiteColor] set];
    NSRectFill(b);
    /* displayRectIgnoringOpacity:inContext: draws the view and every subview into our
     * bitmap regardless of the backing.  The GL surface draws its FALLBACK here (an
     * empty drawRect in the harness), never its composited contents, which is the
     * point of taking both pictures. */
    [content displayRectIgnoringOpacity:b inContext:gctx];
    [NSGraphicsContext restoreGraphicsState];
    g_lastGrab = rep;
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return (png && [png writeToFile:ak_ns(path) atomically:YES]) ? 1 : 0;
    }

/* The environment, for a harness that takes an input path (the real atlas) without a
 * path living in the source.  Returns "" for an unset name, never NULL. */
const char* ux_ak_env(const char* name)
    {
    const char* v = getenv(name);
    return v ? v : "";
    }

/* A file's size in bytes, or -1.  Paired with ux_ak_read_file so the caller allocates
 * (in xc's heap) and the shim only fills it, which keeps one allocator. */
int ux_ak_file_size(const char* path)
    {
    FILE* f = fopen(path, "rb");
    if (!f)
        return -1;
    if (fseek(f, 0, SEEK_END) != 0)
        {
        fclose(f);
        return -1;
        }
    long n = ftell(f);
    fclose(f);
    return (int)n;
    }

int ux_ak_read_file(const char* path, unsigned char* buf, int cap)
    {
    FILE* f = fopen(path, "rb");
    if (!f)
        return -1;
    size_t n = fread(buf, 1, (size_t)cap, f);
    fclose(f);
    return (int)n;
    }

void ux_ak_gl_destroy(void* peer)
    {
    int i = ak_gl_find(peer);
    if (i < 0)
        return;
    if (g_glCtx[i])
        {
        /* Current on the calling thread, per the contract: clearDrawable on a
         * context that is not current is how a GL client crashes on window close. */
        [g_glCtx[i] makeCurrentContext];
        ak_gl_free_offscreen(i); // the FBO, its texture and the IOSurface go with the context
        [g_glCtx[i] clearDrawable];
        [NSOpenGLContext clearCurrentContext];
        g_glCtx[i] = nil;
        }
    [g_glView[i] removeFromSuperview];
    /* Cleared IN PLACE and not compacted: the index is what an outstanding token
     * means, so shuffling entries down would silently point a live token at
     * somebody else's surface. */
    g_glPeer[i] = 0;
    g_glView[i] = nil;
    g_glPf[i] = nil;
    g_glWin[i] = 0;
    }

/* Every surface a window made goes with that window.  Called from the close path
 * BEFORE the window is dropped, so a context still has a drawable to be cleared
 * from. */
void ux_ak_gl_close(int handle)
    {
    for (int i = 0; i < g_glCount; i++)
        {
        if (g_glWin[i] == handle && g_glPeer[i] != 0)
            ux_ak_gl_destroy(g_glPeer[i]);
        }
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
static int ak_handle_of_window(NSWindow* w)
    {
    if (!w)
        return 0;
    for (int i = 1; i < UX_MAXW; i++)
        {
        if (g_win[i] == w)
            return i;
        }
    return 0;
    }
static void ak_schedule_resize(NSWindow* win)
    {
    if (!g_dispatch || !win)
        return;
    int handle = ak_handle_of_window(win);
    if (!handle)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (g_win[handle] != win)
          return; // window went away meanwhile
      if (g_dispatch)
          g_dispatch(9, handle, 0, 0);
    });
    }
// A programmatic resize is reflowed on the next run-loop cycle.  A LIVE drag is reflowed as it
// happens, here, the way a Cocoa app lays out in windowDidResize: the toolkit and the app see the new
// content size at every step of the drag and the window repaints at that size, rather than showing
// white until the mouse comes up.  (Deferring it to the end of the drag dated from an old compiler's
// heap corruption, which crashed in CG and auto-layout here; the live-resize gate runs this path
// under guard malloc.)  windowDidEndLiveResize still sends the final size.
static void ak_windowDidResize(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id note)
    {
    NSWindow* win = [(NSNotification*)note object];
    if ([win inLiveResize])
        {
        int handle = ak_handle_of_window(win);
        if (g_dispatch && handle)
            g_dispatch(9, handle, 0, 0);
        return;
        }
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

/* The frame clock (UXViewDriver.setTurnHook).  An app asks to be called once per turn, and
 * INTERACTIVE AppKit is the case where the app cannot do the calling itself: [NSApp run]
 * owns the thread inside nextEvent, so nothing above the driver ever gets a turn unless the
 * driver provides one.  The turn is a repeating timer on the MAIN QUEUE -- the same
 * machinery ux_ak_close_after_ms uses, on the same thread the neutral loop would have used,
 * which is what makes the callback serialised with every other callback (no lock, no
 * queue) and OUTSIDE any draw (a timer fires between run-loop passes, never inside
 * drawRect).  fn == NULL, or a non-interactive run where the neutral loop does the calling,
 * clears it.  ms 0 means "every turn the loop has", which for a timer is the display rate. */
static void (*g_turn_fn)(void) = NULL;
static NSTimer* g_turn_timer = nil;
static id g_turn_link = nil; // a CADisplayLink (macOS 14 and later)
/* A display link stops while the display sleeps, or while the window is wholly covered, and the turn
 * is the app's whole clock -- its network polling and its logic, not only its frames.  So a timer at
 * the turn's own rate runs beside the link and calls the turn itself whenever the link has been quiet
 * for three of those intervals; while the link ticks it does nothing. */
static NSTimer* g_turn_backup = nil;
static CFAbsoluteTime g_link_last = 0;

/* The turn, paced by the DISPLAY.  An NSTimer fires when the run loop gets round to it, so the app's
 * frames landed 10-19 ms apart on a 60 Hz screen; a display link fires once per refresh of the
 * screen the window is on, and follows it to another screen at that one's rate.  It calls back on the
 * main run loop, and is added in the COMMON modes, so a live resize, a scroller drag and a menu do not
 * stop it (they run the loop in NSEventTrackingRunLoopMode).  It is used for a turn of 30 a second or
 * more (ms 0..33, held to at most 1000/ms a second); a slower turn keeps the timer, as does headless
 * running and a system before macOS 14. */
@interface UXTurnTarget : NSObject
@end
@implementation UXTurnTarget
- (void)tick:(id)link
    {
    (void)link;
    g_link_last = CFAbsoluteTimeGetCurrent();
    if (g_turn_fn)
        g_turn_fn();
    }
@end
static UXTurnTarget* g_turn_target = nil;
static int ak_turn_link(int ms)
    {
    if (ms > 33)
        return 0;
    NSView* v = nil;
    for (int h = 1; h < UX_MAXW && !v; h++)
        v = g_win[h] ? [g_win[h] contentView] : nil;
    if (@available(macOS 14.0, *))
        {
        if (!g_turn_target)
            g_turn_target = [UXTurnTarget new];
        CADisplayLink* l = v ? [v displayLinkWithTarget:g_turn_target selector:@selector(tick:)]
                             : [[NSScreen mainScreen] displayLinkWithTarget:g_turn_target selector:@selector(tick:)];
        if (!l)
            return 0;
        if (ms > 0)
            {
            float most = 1000.0f / (float)ms;
            CAFrameRateRange r = { 1.0f, most, most };
            l.preferredFrameRateRange = r;
            }
        [l addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        g_turn_link = l;
        return 1;
        }
    return 0;
    }
/* Test: the refresh rate of the screen the first window is on (60 where it cannot be read). */
int ux_ak_test_screen_hz(void)
    {
    NSScreen* sc = nil;
    for (int h = 1; h < UX_MAXW && !sc; h++)
        sc = g_win[h] ? [g_win[h] screen] : nil;
    if (!sc)
        sc = [NSScreen mainScreen];
    if (@available(macOS 12.0, *))
        return sc ? (int)sc.maximumFramesPerSecond : 60;
    return 60;
    }
/* Test: pause (1) or resume (0) the turn's display link, as a sleeping display or a covered window
 * stops it. */
void ux_ak_test_pause_turn_link(int on)
    {
    if (g_turn_link)
        ((CADisplayLink*)g_turn_link).paused = on ? YES : NO;
    }
/* Test: 1 when the turn is paced by the display link, 0 by the timer, -1 when there is none. */
int ux_ak_turn_paced_by_display(void)
    {
    return g_turn_link ? 1 : (g_turn_timer ? 0 : -1);
    }

void ux_ak_set_turn_hook(void* fn, int ms)
    {
    if (g_turn_timer != nil)
        {
        [g_turn_timer invalidate];
        g_turn_timer = nil;
        }
    if (g_turn_link != nil)
        {
        [(CADisplayLink*)g_turn_link invalidate];
        g_turn_link = nil;
        }
    if (g_turn_backup != nil)
        {
        [g_turn_backup invalidate];
        g_turn_backup = nil;
        }
    g_turn_fn = (void (*)(void))fn;
    if (g_turn_fn == NULL || !g_interactive)
        {
        return;
        }
    double secs = ms > 0 ? (double)ms / 1000.0 : (1.0 / 60.0);
    if (ak_turn_link(ms))
        {
        g_link_last = CFAbsoluteTimeGetCurrent();
        g_turn_backup = [NSTimer timerWithTimeInterval:secs
                                               repeats:YES
                                                 block:^(NSTimer* t) {
                                                   (void)t;
                                                   if (g_turn_fn && CFAbsoluteTimeGetCurrent() - g_link_last > 3.0 * secs)
                                                       g_turn_fn();
                                                 }];
        [[NSRunLoop currentRunLoop] addTimer:g_turn_backup forMode:NSRunLoopCommonModes];
        return;
        }
    // In the COMMON modes, not just the default one: a live resize, a scroller drag and a menu
    // tracking all run the loop in NSEventTrackingRunLoopMode, and a default-mode timer does not fire
    // there -- the app's turn (its redraw, its geometry check) stopped for the whole drag.
    g_turn_timer = [NSTimer timerWithTimeInterval:secs
                                          repeats:YES
                                            block:^(NSTimer* t) {
                                              (void)t;
                                              if (g_turn_fn)
                                                  {
                                                  g_turn_fn();
                                                  }
                                            }];
    [[NSRunLoop currentRunLoop] addTimer:g_turn_timer forMode:NSRunLoopCommonModes];
    }

/* ---- the live-resize probe (test only) ------------------------------------------------------
 * A real drag needs a hand on the mouse, but an ANIMATED resize is a live resize to AppKit
 * (inLiveResize is YES at every step, windowDidResize fires per step), and running the loop in
 * NSEventTrackingRunLoopMode is what the drag's tracking does between steps.  Off the current
 * callout (so the turn timer is free to fire): resize the content to w x h, animated, then run the
 * loop in the tracking mode for ms, then set done. */
static int g_liveProbeDone = 0;
void ux_ak_test_live_resize(int handle, int w, int h, int ms)
    {
    g_liveProbeDone = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
      NSWindow* win = g_win[handle];
      if (win)
          {
          NSRect fr = [win frameRectForContentRect:NSMakeRect(0, 0, w, h)];
          NSRect cur = [win frame];
          fr.origin = NSMakePoint(cur.origin.x, NSMaxY(cur) - fr.size.height); // keep the top edge
          [win setFrame:fr display:YES animate:YES];
          NSDate* end = [NSDate dateWithTimeIntervalSinceNow:ms / 1000.0];
          while ([end timeIntervalSinceNow] > 0)
              [[NSRunLoop currentRunLoop] runMode:NSEventTrackingRunLoopMode beforeDate:end];
          }
      g_liveProbeDone = 1;
    });
    }
int ux_ak_test_live_done(void)
    {
    return g_liveProbeDone;
    }
int ux_ak_in_live_resize(int handle)
    {
    NSWindow* win = g_win[handle];
    return win && [win inLiveResize] ? 1 : 0;
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
    [v registerForDraggedTypes:@[ NSPasteboardTypeFileURL, AK_ROW_TYPE ]];
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
    /* Before the window goes: a live context needs a drawable to be cleared from,
     * and after this line there is not one. */
    ux_ak_gl_close(handle);
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
    [g_win[handle] setTitle:ak_ns(s)];
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
        [g_win[handle] setSubtitle:ak_ns(s ? s : "")];
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

// The title-bar icon.  A GEM window carries an icon SLICE that the AES draws (WF_ICON — the "proxy /
// document icon"); macOS has no window-title image at all, but it has the PROXY ICON: the icon of the
// document a window stands for, shown at the left of the title and driven by a file URL.  So a name
// that is a path IS that document, and a bare theme slice name has no Cocoa counterpart — it is
// cleared rather than guessed at, since a made-up URL would show a bogus generic document.
void ux_ak_window_set_icon(int handle, const char* s)
    {
    if (!g_win[handle])
        return;
    if (!s || !s[0] || !strchr(s, '/'))
        {
        [g_win[handle] setRepresentedURL:nil];
        return;
        }
    [g_win[handle] setRepresentedURL:[NSURL fileURLWithPath:ak_ns(s)]];
    }
/* Sound: signed 16-bit mono PCM wrapped as an in-memory WAV and played by NSSound, which mixes
 * overlapping sounds itself.  Each NSSound is kept until it has finished (pruned on the next play),
 * because one released mid-play stops.  1 when it started. */
static NSMutableArray* g_sounds;
int ux_ak_audio_play(const short* pcm, int frames, int rate)
    {
    if (!pcm || frames <= 0 || rate <= 0)
        return 0;
    if (!g_sounds)
        g_sounds = [NSMutableArray array];
    for (NSInteger k = (NSInteger)[g_sounds count] - 1; k >= 0; k--)
        if (![(NSSound*)g_sounds[(NSUInteger)k] isPlaying])
            [g_sounds removeObjectAtIndex:(NSUInteger)k];
    uint32_t dataBytes = (uint32_t)frames * 2;
    NSMutableData* wav = [NSMutableData dataWithLength:44 + dataBytes];
    unsigned char* h = (unsigned char*)[wav mutableBytes];
    #define PUT32(o, v) do { uint32_t _v = (uint32_t)(v); h[o] = _v & 255; h[o+1] = (_v >> 8) & 255; h[o+2] = (_v >> 16) & 255; h[o+3] = (_v >> 24) & 255; } while (0)
    #define PUT16(o, v) do { uint32_t _v = (uint32_t)(v); h[o] = _v & 255; h[o+1] = (_v >> 8) & 255; } while (0)
    memcpy(h, "RIFF", 4); PUT32(4, 36 + dataBytes); memcpy(h + 8, "WAVEfmt ", 8);
    PUT32(16, 16); PUT16(20, 1); PUT16(22, 1); PUT32(24, rate); PUT32(28, rate * 2); PUT16(32, 2); PUT16(34, 16);
    memcpy(h + 36, "data", 4); PUT32(40, dataBytes);
    #undef PUT32
    #undef PUT16
    for (int i = 0; i < frames; i++)
        {
        uint16_t v = (uint16_t)pcm[i];
        h[44 + i * 2] = v & 255;
        h[45 + i * 2] = (v >> 8) & 255;
        }
    NSSound* snd = [[NSSound alloc] initWithData:wav];
    if (!snd || ![snd play])
        return 0;
    [g_sounds addObject:snd];
    return 1;
    }
/* For a gate: run the run loop for ms (NSSound reports its state there, and a headless test has no
 * loop of its own). */
void ux_ak_run_for(int ms)
    {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:ms / 1000.0]];
    }
/* For a gate: the process's physical footprint in KB (what Activity Monitor and time -l report). */
int ux_ak_test_footprint_kb(void)
    {
    task_vm_info_data_t info;
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) != KERN_SUCCESS)
        return -1;
    return (int)(info.phys_footprint / 1024);
    }
/* For a gate: how many sounds are playing now. */
int ux_ak_audio_playing(void)
    {
    int n = 0;
    for (NSSound* s in g_sounds)
        if ([s isPlaying])
            n++;
    return n;
    }
/* The APPLICATION's icon while it runs: the Dock tile (and the app switcher).  The pixels (fmt 0 =
 * RGBA bytes, 1 = 0xAARRGGBB words; straight alpha, top-down) are copied into a non-premultiplied
 * bitmap rep, so the caller's buffer may change afterwards.  1 when set. */
int ux_ak_app_set_icon(const unsigned char* data, int w, int h, int fmt)
    {
    if (!data || w <= 0 || h <= 0)
        return 0;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bitmapFormat:NSBitmapFormatAlphaNonpremultiplied bytesPerRow:w * 4 bitsPerPixel:32];
    if (!rep)
        return 0;
    unsigned char* out = [rep bitmapData];
    for (int i = 0; i < w * h; i++)
        {
        const unsigned char* q = data + (size_t)i * 4;
        out[i * 4 + 0] = fmt == 1 ? q[2] : q[0];
        out[i * 4 + 1] = q[1];
        out[i * 4 + 2] = fmt == 1 ? q[0] : q[2];
        out[i * 4 + 3] = q[3];
        }
    NSImage* img = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [img addRepresentation:rep];
    [NSApplication sharedApplication]; /* NSApp may not exist yet in a headless run */
    [NSApp setApplicationIconImage:img];
    return [NSApp applicationIconImage] != nil ? 1 : 0;
    }
/* Read-back for a gate: the running icon's pixel size, and its colour (0xRRGGBB) at (x,y) from the
 * top-left, out of the image AppKit now holds.  -1 = no icon set. */
int ux_ak_app_icon_pixel(int x, int y, int* outW, int* outH)
    {
    /* Whatever image AppKit now holds, rendered at its own size into a known RGBA bitmap: the read
     * does not depend on how AppKit stores it. */
    NSImage* img = [NSApp applicationIconImage];
    if (!img)
        return -1;
    int w = (int)lround([img size].width), h = (int)lround([img size].height);
    if (outW)
        *outW = w;
    if (outH)
        *outH = h;
    if (w <= 0 || h <= 0 || x < 0 || y < 0 || x >= w || y >= h)
        return -1;
    NSRect r = NSMakeRect(0, 0, w, h);
    CGImageRef cg = [img CGImageForProposedRect:&r context:nil hints:nil];
    if (!cg)
        return -1;
    unsigned char* px = calloc((size_t)w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), cg); /* row 0 of px is the TOP row */
    CGContextRelease(c);
    CGColorSpaceRelease(cs);
    unsigned char* q = px + ((size_t)y * w + x) * 4;
    int rgb = (q[0] << 16) | (q[1] << 8) | q[2];
    free(px);
    return rgb;
    }
/* The window's content as it is on screen, region (x, y, w, h) in the toolkit's (top-left) content
 * coordinates, into out as w * h opaque 0xAARRGGBB words.  The content view renders itself and every
 * subview into a bitmap of w x h POINTS (1x: a movie of the window is its point size, whatever the
 * screen's scale): the draw view's 2-D pass with the GL frame painted into it, the native controls
 * and scroll views, any overlay.  The window's own background, which the toolkit does not paint, is
 * filled in first, as it shows on screen.  Headless or interactive alike: both have the views. */
int ux_ak_window_snapshot(int handle, int x, int y, int w, int h, uint32_t* out)
    {
    if (handle <= 0 || handle >= UX_MAXW || !g_view[handle] || w <= 0 || h <= 0 || !out)
        return 0;
    NSWindow* win = g_win[handle];
    NSView* v = win ? [win contentView] : g_view[handle];
    if (!v)
        return 0;
    int ok = 0;
    @autoreleasepool
        {
        NSRect b = [v bounds];
        /* the region in the view's own coordinates: a non-flipped view counts y from the bottom */
        NSRect r = NSMakeRect(b.origin.x + x, [v isFlipped] ? b.origin.y + y : b.origin.y + b.size.height - y - h, w, h);
        NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
            isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32];
        NSGraphicsContext* gctx = rep ? [NSGraphicsContext graphicsContextWithBitmapImageRep:rep] : nil;
        if (gctx)
            {
            [rep setSize:NSMakeSize(w, h)];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:gctx];
            NSColor* bg = win ? [win backgroundColor] : [NSColor windowBackgroundColor];
            [[bg colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]] set];
            NSRectFill(NSMakeRect(0, 0, w, h));
            /* shift the view so the region lands at the bitmap's origin */
            CGContextTranslateCTM([gctx CGContext], -(r.origin.x - b.origin.x), -(r.origin.y - b.origin.y));
            [v displayRectIgnoringOpacity:r inContext:gctx];
            [NSGraphicsContext restoreGraphicsState];
            const unsigned char* p = [rep bitmapData];
            long row = (long)[rep bytesPerRow];
            for (int j = 0; j < h; j++)
                for (int i = 0; i < w; i++)
                    {
                    const unsigned char* q = p + j * row + i * 4;
                    out[j * w + i] = 0xFF000000u | ((uint32_t)q[0] << 16) | ((uint32_t)q[1] << 8) | q[2];
                    }
            ok = 1;
            }
        }
    return ok;
    }
// Read-back, so a test can assert the WINDOW shows it rather than that the call returned.
int ux_ak_window_icon(int handle, char* out, int cap)
    {
    if (out && cap > 0)
        out[0] = 0;
    if (!g_win[handle] || !out || cap <= 0)
        return 0;
    NSURL* u = [g_win[handle] representedURL];
    if (!u)
        return 0;
    NSString* p = [u path];
    if (!p)
        return 0;
    snprintf(out, (size_t)cap, "%s", [p UTF8String]);
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
    /* Headless, every invalidate renders the window into a NEW window-sized bitmap, which AppKit
     * hands back autoreleased.  A headless app never drains an autorelease pool of its own, so
     * without this one each frame's bitmap stayed alive: one whole frame leaked per present (the
     * client measured 4.26 MB a frame at 1280x832 and 227 GB over a session).  The one kept for
     * read-back is held by g_lastRep, a strong reference, and survives the pool. */
    @autoreleasepool
        {
        NSRect b = [v bounds];
        NSBitmapImageRep* rep = [v bitmapImageRepForCachingDisplayInRect:b];
        if (rep)
            {
            [v cacheDisplayInRect:b toBitmapImageRep:rep];
            g_lastRep = rep;
            }
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
void ux_ak_fill(int x, int y, int w, int h, int r, int g, int b, int a)
    {
    [[NSColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a / 255.0] setFill];
    /* SOURCE OVER, not NSRectFill: NSRectFill composites with COPY, which writes the fill
     * colour straight in -- so a translucent rectangle came out solid.  Blending is the
     * point of the alpha, and for an opaque colour source-over is the same pixels. */
    NSRectFillUsingOperation(NSMakeRect(x, y, w, h), NSCompositingOperationSourceOver);
    }
/* A bitmap region drawn into the current 2-D context: drawPixels.  The bitmap is wrapped in a
 * CGImage ONCE and kept, keyed by its address, size and layout -- the map's atlas is 28 MB and a
 * panel draws ~80 icons from it every frame, so wrapping it per call would be the whole cost.  The
 * CGImage reads the caller's memory directly (no copy), which is why the bytes must not change once
 * drawn.  Eight entries, least recently made replaced: a client draws from a few sheets, not many. */
#define AK_PIXCACHE 8
static struct
    {
    const void* data;
    int w, h, format;
    CGImageRef img;
    } g_pixCache[AK_PIXCACHE];
static int g_pixNext = 0;
static CGImageRef ak_pixels_image(const void* data, int w, int h, int format)
    {
    for (int i = 0; i < AK_PIXCACHE; i++)
        if (g_pixCache[i].img && g_pixCache[i].data == data && g_pixCache[i].w == w
            && g_pixCache[i].h == h && g_pixCache[i].format == format)
            return g_pixCache[i].img;
    /* sRGB, the space a PNG and the browser's canvas are in: tagged "device RGB" the pixels are
     * converted through the display's profile and a pure red comes out (244,45,26). */
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, data, (size_t)w * h * 4, NULL);
    /* Straight alpha in both layouts: R,G,B,A bytes, or 0xAARRGGBB words in native (little-endian)
     * order, which is B,G,R,A in memory. */
    CGBitmapInfo bi = format == 1 ? (kCGImageAlphaFirst | kCGBitmapByteOrder32Little)
                                  : (kCGImageAlphaLast | kCGBitmapByteOrderDefault);
    CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs, bi, dp, NULL, true,
                                   kCGRenderingIntentDefault);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    if (!img)
        return NULL;
    int k = g_pixNext;
    g_pixNext = (g_pixNext + 1) % AK_PIXCACHE;
    if (g_pixCache[k].img)
        CGImageRelease(g_pixCache[k].img);
    g_pixCache[k].data = data;
    g_pixCache[k].w = w;
    g_pixCache[k].h = h;
    g_pixCache[k].format = format;
    g_pixCache[k].img = img;
    return img;
    }
void ux_ak_draw_pixels(const void* data, int w, int h, int format, int sx, int sy, int sw, int sh,
                       int dx, int dy, int dw, int dh, int alpha)
    {
    CGContextRef c = [[NSGraphicsContext currentContext] CGContext];
    if (!c || !data || w <= 0 || h <= 0 || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0 || alpha <= 0)
        return;
    CGImageRef img = ak_pixels_image(data, w, h, format);
    if (!img)
        return;
    /* The region, in the bitmap's own pixels, top row first: CGImageCreateWithImageInRect measures
     * from the image's first row, which is the bitmap's top. */
    CGImageRef part = CGImageCreateWithImageInRect(img, CGRectMake(sx, sy, sw, sh));
    if (!part)
        return;
    CGContextSaveGState(c);
    CGContextSetAlpha(c, alpha >= 255 ? 1.0 : alpha / 255.0);
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    /* The toolkit's context is flipped (y down) and an image is drawn y-up, so it is flipped about
     * its destination or it lands upside down. */
    CGContextTranslateCTM(c, dx, dy + dh);
    CGContextScaleCTM(c, 1, -1);
    CGContextDrawImage(c, CGRectMake(0, 0, dw, dh), part);
    CGContextRestoreGState(c);
    CGImageRelease(part);
    }

/* A view's drawing stays inside its frame, as an NSView's does: the walk clips to the view's rect
 * around its drawRect (and around a clipping view's whole subtree), and pops it after. */
void ux_ak_clip_push(int x, int y, int w, int h)
    {
    CGContextRef c = [[NSGraphicsContext currentContext] CGContext];
    if (!c)
        return;
    CGContextSaveGState(c);
    CGContextClipToRect(c, CGRectMake(x, y, w, h));
    }
void ux_ak_clip_round(int x, int y, int w, int h, int r)
    {
    CGContextRef c = [[NSGraphicsContext currentContext] CGContext];
    if (!c)
        return;
    CGContextSaveGState(c);
    if (w <= 0 || h <= 0)
        {
        CGContextClipToRect(c, CGRectZero);
        return;
        }
    CGFloat rr = r * 2 > w ? w / 2.0 : r * 2 > h ? h / 2.0 : r;
    if (rr <= 0)
        {
        CGContextClipToRect(c, CGRectMake(x, y, w, h));
        return;
        }
    CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(x, y, w, h), rr, rr, NULL);
    CGContextAddPath(c, path);
    CGContextClip(c);
    CGPathRelease(path);
    }
void ux_ak_clip_pop(void)
    {
    CGContextRef c = [[NSGraphicsContext currentContext] CGContext];
    if (c)
        CGContextRestoreGState(c);
    }

/* A transparency layer: everything drawn until the matching end goes into a buffer that starts
 * EMPTY, and is composited over what was already drawn when it ends.  A clear inside it erases the
 * layer's own pixels only.  It is how a view that asked for its own surface keeps that meaning in
 * the one 2-D surface, with no native layer. */
void ux_ak_layer_begin(int x, int y, int w, int h)
    {
    CGContextRef c = [[NSGraphicsContext currentContext] CGContext];
    if (!c)
        return;
    CGContextSaveGState(c);
    CGContextBeginTransparencyLayerWithRect(c, CGRectMake(x, y, w, h), NULL);
    }
void ux_ak_layer_end(void)
    {
    CGContextRef c = [[NSGraphicsContext currentContext] CGContext];
    if (!c)
        return;
    CGContextEndTransparencyLayer(c);
    CGContextRestoreGState(c);
    }
void ux_ak_clear(int x, int y, int w, int h)
    {
    /* CLEAR, not a fill: it takes the rect back to transparent whatever is under it, so a layer that
     * composites over a map starts empty each frame.  A source-over fill at alpha 0 (the obvious
     * stand-in) would paint nothing at all and leave last frame's ink in place. */
    NSRectFillUsingOperation(NSMakeRect(x, y, w, h), NSCompositingOperationClear);
    }
void ux_ak_text(const char* s, int x, int y, int r, int g, int b, int a, int size)
    {
    NSFont* f = [NSFont systemFontOfSize:(size > 0 ? size : 12)];
    NSDictionary* attr = @{NSForegroundColorAttributeName :
                            [NSColor colorWithRed:r / 255.0
                                            green:g / 255.0
                                             blue:b / 255.0
                                            alpha:a / 255.0],
                        NSFontAttributeName : f};
    [ak_ns(s) drawAtPoint:NSMakePoint(x, y) withAttributes:attr];
    }
// How wide a string renders in the UI font — what the toolkit breaks lines with.  Rounded UP: a
// fractional width that rounds down puts a line one pixel over the measure and it wraps short.
int ux_ak_text_width(const char* s, int size)
    {
    NSFont* f = [NSFont systemFontOfSize:(size > 0 ? size : 12)];
    NSDictionary* a = @{NSFontAttributeName : f};
    NSSize sz = [ak_ns(s) sizeWithAttributes:a];
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
/* The same clock at full resolution.  systemUptime is a double, so the microseconds
 * were always there -- nowMs was simply throwing them away, and a frame is usually
 * under a millisecond. */
int ux_ak_now_us(void)
    {
    static double base = 0;
    double now = [[NSProcessInfo processInfo] systemUptime];
    if (base == 0)
        base = now;
    return (int)((now - base) * 1000000.0);
    }
// Styled measurement — the counterpart of ux_ak_text_font, and it must agree with it.
int ux_ak_text_width_font(const char* s, const char* family, int size, int bold, int italic)
    {
    CGFloat sz = size > 0 ? size : 12;
    NSFont* f = family && *family ? [NSFont fontWithName:ak_ns(family) size:sz] : nil;
    if (!f)
        f = [NSFont systemFontOfSize:sz];
    NSFontManager* fm = [NSFontManager sharedFontManager];
    if (bold)
        f = [fm convertFont:f toHaveTrait:NSBoldFontMask];
    if (italic)
        f = [fm convertFont:f toHaveTrait:NSItalicFontMask];
    NSSize z = [ak_ns(s) sizeWithAttributes:@{NSFontAttributeName : f}];
    return (int)ceil(z.width);
    }
// Styled text: a named family + bold/italic (the toolkit font-chooser preview).
void ux_ak_text_font(const char* s, int x, int y, int r, int g, int b,
                     const char* family, int size, int bold, int italic)
    {
    CGFloat sz = size > 0 ? size : 12;
    NSFont* f = [NSFont fontWithName:ak_ns(family) size:sz];
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
    [ak_ns(s) drawAtPoint:NSMakePoint(x, y) withAttributes:a];
    }

/* A font at a WEIGHT, not just bold: the CSS 100..900 scale mapped onto AppKit's NSFontWeight*,
   applied through a font descriptor so a named family is honoured and a family without the exact
   weight resolves to the nearest it has (the whole point -- the map's 600 is a semibold, and a bool
   `bold` cannot say it).  Italic is a trait conversion on top, as in ux_ak_text_font. */
static NSFont* ak_weighted_font(const char* family, CGFloat sz, int weight, int italic)
    {
    CGFloat w;
    if (weight <= 100)      w = -0.80;  /* thin */
    else if (weight <= 300) w = -0.40;  /* light */
    else if (weight <= 400) w = 0.00;   /* regular */
    else if (weight <= 500) w = 0.23;   /* medium */
    else if (weight <= 600) w = 0.30;   /* semibold */
    else if (weight <= 700) w = 0.40;   /* bold */
    else if (weight <= 800) w = 0.56;   /* heavy */
    else                    w = 0.62;   /* black */
    NSDictionary* traits = @{NSFontWeightTrait : @(w)};
    NSDictionary* attrs = (family && *family)
        ? @{NSFontFamilyAttribute : ak_ns(family), NSFontTraitsAttribute : traits}
        : @{NSFontTraitsAttribute : traits};
    NSFont* f = [NSFont fontWithDescriptor:[NSFontDescriptor fontDescriptorWithFontAttributes:attrs] size:sz];
    if (!f)
        f = [NSFont systemFontOfSize:sz weight:w];
    if (italic)
        f = [[NSFontManager sharedFontManager] convertFont:f toHaveTrait:NSItalicFontMask];
    return f;
    }

// The measure at a NUMERIC weight — the counterpart of ux_ak_text_weight below, through the SAME
// ak_weighted_font, so a string is measured in the face it will be drawn in.
int ux_ak_text_width_weight(const char* s, const char* family, int size, int weight, int italic)
    {
    NSFont* f = ak_weighted_font(family, (CGFloat)(size > 0 ? size : 12), weight, italic);
    NSSize z = [ak_ns(s) sizeWithAttributes:@{NSFontAttributeName : f}];
    return (int)ceil(z.width);
    }
// The FACE's ascent: the distance from the top of the line to the baseline, which is where
// NSBezierPath/NSAttributedString put a drawAtPoint in this flipped context.  Rounded UP for the same
// reason a width is: a caller converting a baseline into the seam's y must not land inside the glyphs.
int ux_ak_text_ascent(const char* family, int size, int weight, int italic)
    {
    NSFont* f = ak_weighted_font(family, (CGFloat)(size > 0 ? size : 12), weight, italic);
    return (int)ceil([f ascender]);
    }

void ux_ak_text_weight(const char* s, int x, int y, const char* family, int size,
                       int weight, int italic, int r, int g, int b, int a)
    {
    NSFont* f = ak_weighted_font(family, (CGFloat)(size > 0 ? size : 12), weight, italic);
    NSDictionary* at = @{NSForegroundColorAttributeName :
                             [NSColor colorWithRed:r / 255.0
                                             green:g / 255.0
                                              blue:b / 255.0
                                             alpha:a / 255.0],
                         NSFontAttributeName : f};
    [ak_ns(s) drawAtPoint:NSMakePoint(x, y) withAttributes:at];
    }
// A filled polygon from a flat x,y,x,y... array — the general form of ux_ak_tri, and what the
// neutral painter hands down for stroke quads, joins, caps and gradient bands alike.
void ux_ak_poly(const short* xy, int n, int r, int g, int b, int a)
    {
    if (n < 3)
        return;
    [[NSColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a / 255.0] setFill];
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
//   dash/ndash/phase: the on/off run in device POINTS and how far into it the stroke starts (ndash 0
// = solid).  The phase may be negative, which starts the run before its beginning: exactly what
// lineDashOffset does, and what a crawling border is.
//   width: device points, and may be FRACTIONAL — setLineWidth: takes a CGFloat, so a 1.536-pt border
// is exactly that.
void ux_ak_stroke_path(const int* ops, int n, double width, int startCap, int endCap, int join,
                       const int* dash, int ndash, int phase, int r, int g, int b, int a)
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
    // join: 0 miter, 1 round, 2 bevel (UXJOIN_*).
    [p setLineJoinStyle:(join == 0 ? NSLineJoinStyleMiter
                                   : (join == 2 ? NSLineJoinStyleBevel : NSLineJoinStyleRound))];
    // The dash run.  NSBezierPath takes it in the same units as the line width (points), and it
    // restarts the run at each subpath — which is the rule the seam promises, so nothing has to be
    // split here.  A zero or negative entry is lifted to 1, as a dasher with a zero-length run either
    // stalls or is undefined.
    if (ndash > 0)
        {
        CGFloat pat[8];
        int k = ndash > 8 ? 8 : ndash;
        for (int j = 0; j < k; j++)
            pat[j] = dash[j] > 0 ? (CGFloat)dash[j] : (CGFloat)1;
        [p setLineDash:pat count:(NSInteger)k phase:(CGFloat)phase];
        }
    else
        {
        [p setLineDash:NULL count:0 phase:(CGFloat)0];
        }
    [[NSColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a / 255.0] setStroke];
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
// Which window a pulled mouse event was addressed to.  The INTERACTIVE path gets this for free (the
// content view that got the press hands its own handle to the dispatch callback); the headless pump
// has it too — the NSEvent says which window it is — so record it here rather than let the driver
// fall back to "window 1" and route a second window's clicks into the first.
static int g_lastMouseWin = 0;
int ux_ak_last_mouse_win(void)
    {
    return g_lastMouseWin;
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
    /* The headless pump runs once a turn and nothing else drains a pool here: anything AppKit
     * autoreleases during the turn is released at the end of this one. */
    @autoreleasepool
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
        // A frame clock turns this poll into the clock's own period: the deadline IS the wait, so a
        // headless turn comes round when the app asked rather than on the toolkit's default poll.  The
        // extra run-loop pass below stays with the default poll only -- with a deadline it would put
        // its own wait in FRONT of the deadline and make a turn cost twice what was asked for.
        double secs = 0.05;
        if (timeoutMs > 0)
            {
            secs = (double)timeoutMs / 1000.0;
            }
        else
            {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            }
        NSEvent* e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                        untilDate:[NSDate dateWithTimeIntervalSinceNow:secs]
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
            g_lastMouseWin = ak_handle_of_window([e window]);
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
    NSString* t = ak_ns(title);
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
        initWithTitle:ak_ns(text)
               action:sel_registerName("xgMenu:")
        keyEquivalent:@""];
    [it setTag:tag];
    [it setTarget:ak_menu_target()];
    [it setState:(checked ? NSControlStateValueOn : NSControlStateValueOff)];
    [it setEnabled:(disabled ? NO : YES)];
    [s addItem:it];
    }
/* A menu item's shortcut: Command (and Shift) with `key`, an uppercase letter or a mark.  AppKit
 * matches it before the window's keyDown:, so the toolkit never sees the key as typing. */
void ux_ak_menu_item_key(void* sub, int tag, int key, int shift)
    {
    NSMenuItem* it = [(__bridge NSMenu*)sub itemWithTag:tag];
    if (!it || key <= 0)
        return;
    /* lower case for Command alone; with Shift, the upper-case letter, which is what the event's
     * charactersIgnoringModifiers holds (it keeps Shift) */
    unichar c = (unichar)((!shift && key >= 'A' && key <= 'Z') ? key + 32 : key);
    [it setKeyEquivalent:[NSString stringWithCharacters:&c length:1]];
    [it setKeyEquivalentModifierMask:NSEventModifierFlagCommand | (shift ? NSEventModifierFlagShift : 0)];
    }
/* For tests: files dropped on window `handle` at (x, y), delivered as a real drop is. */
int ux_ak_test_drop_file(int handle, const char* path, int x, int y)
    {
    if (handle <= 0 || handle >= UX_MAXW || !g_view[handle])
        return 0;
    NSURL* u = [NSURL fileURLWithPath:ak_ns(path)];
    return ak_deliver_files(g_view[handle], @[ u ], NSMakePoint(x, y));
    }
/* For tests: a key press offered to the main menu the way AppKit offers one before keyDown:
 * (performKeyEquivalent:).  1 if a menu item took it. */
int ux_ak_test_menu_press(int key, int cmd, int shift)
    {
    unichar lower = (unichar)((key >= 'A' && key <= 'Z') ? key + 32 : key);
    unichar typed = shift ? (unichar)key : lower;
    NSEventModifierFlags f = (cmd ? NSEventModifierFlagCommand : 0) | (shift ? NSEventModifierFlagShift : 0);
    NSEvent* e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:f
                                 timestamp:0 windowNumber:0 context:nil
                                characters:[NSString stringWithCharacters:&typed length:1]
               charactersIgnoringModifiers:[NSString stringWithCharacters:&typed length:1] /* keeps Shift, as a real one does */
                                 isARepeat:NO keyCode:0];
    return [[NSApp mainMenu] performKeyEquivalent:e] ? 1 : 0;
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
    NSArray* ls = [ak_ns(lines) componentsSeparatedByString:@"|"];
    [a setMessageText:[ls count] > 0 ? ls[0] : @""];
    if ([ls count] > 1)
        {
        NSRange r = NSMakeRange(1, [ls count] - 1);
        [a setInformativeText:[[ls subarrayWithRange:r] componentsJoinedByString:@"\n"]];
        }
    NSArray* bs = [ak_ns(buttons) componentsSeparatedByString:@"|"];
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
        [p setPrompt:ak_ns(prompt)];
    if (startDir && *startDir)
        [p setDirectoryURL:[NSURL fileURLWithPath:ak_ns(startDir)]];
    if ([p runModal] != NSModalResponseOK)
        return 0;
    NSString* path = [[p URL] path];
    if (!path)
        return 0;
    strncpy(out, [path UTF8String], outCap - 1);
    out[outCap - 1] = 0;
    return 1;
    }

// NSSavePanel: the name field starts as defaultName, and the panel itself asks before replacing.
int ux_ak_save_panel(const char* prompt, const char* startDir, const char* defaultName, char* out, int outCap)
    {
    if (!g_interactive)
        return 0;
    NSSavePanel* p = [NSSavePanel savePanel];
    [p setCanCreateDirectories:YES];
    if (prompt && *prompt)
        [p setMessage:ak_ns(prompt)];
    if (startDir && *startDir)
        [p setDirectoryURL:[NSURL fileURLWithPath:ak_ns(startDir)]];
    if (defaultName && *defaultName)
        [p setNameFieldStringValue:ak_ns(defaultName)];
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
    NSFont* init = [NSFont fontWithName:ak_ns(inFamily) size:sz];
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
static NSView* g_ctl[UX_MAXW][UX_MAXN]; // ARC-strong; [handle][node] -> native control (or nil)
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
    if (!content || node < 0 || node >= UX_MAXN)
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
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
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
    if (!content || node < 0 || node >= UX_MAXN)
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
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
        return;
    id c = g_ctl[handle][node];
    if ([c isKindOfClass:[NSPopUpButton class]])
        {
        [(NSPopUpButton*)c addItemWithTitle:ak_ns((title ? title : ""))];
        }
    }
void ux_ak_popup_select(int handle, int node, int i)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
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
    if (!content || node < 0 || node >= UX_MAXN)
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
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
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
    if (!content || node < 0 || node >= UX_MAXN)
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
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
        return;
    id c = g_ctl[handle][node];
    if ([c isKindOfClass:[NSSegmentedControl class]] && seg >= 0)
        {
        [(NSSegmentedControl*)c setLabel:ak_ns((label ? label : "")) forSegment:seg];
        }
    }
void ux_ak_seg_select(int handle, int node, int seg)
    {
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
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
    if (!content || node < 0 || node >= UX_MAXN)
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
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
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
    return (node >= 0 && node < UX_MAXN && g_ctl[handle][node] != nil) ? 1 : 0;
    }
// How many native subview controls exist for a window (g_ctl slots) — for verifying realization.
int ux_ak_control_count(int handle)
    {
    if (handle < 0 || handle >= UX_MAXW)
        return 0;
    int n = 0;
    for (int i = 0; i < UX_MAXN; i++)
        {
        if (g_ctl[handle][i])
            n++;
        }
    return n;
    }

// A native NSTextField syncs with the toolkit's field buffer: native edits are written back (so
// field.text() works), and setText from the app is pushed to the field (so e.g. Clear Field shows).
static id g_field_delegate = 0;
static char* g_field_buf[UX_MAXW][UX_MAXN]; // raw ptr to the toolkit's field buffer (not ObjC)
static int g_field_cap[UX_MAXW][UX_MAXN];
static void (*g_field_changed)(int, int) = 0; // -> the neutral field's onChange (handle, node)
void ux_ak_set_field_hooks(void* changed)
    {
    g_field_changed = (void (*)(int, int))changed;
    }
// The same delegate's other half: Return.  controlTextDidEndEditing fires for every way a field
// can lose the focus, so the movement in the notification's userInfo is what says whether the key
// was Return; anything else (a Tab, a click elsewhere, the window closing) is not a submit.
static void (*g_field_submit)(int, int) = 0; // -> the neutral field's onSubmit (handle, node)
void ux_ak_set_field_submit_hooks(void* submitted)
    {
    g_field_submit = (void (*)(int, int))submitted;
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
// Return, as opposed to any other way a field gives up the focus.  AppKit reports the movement
// that ended editing in the notification's userInfo (the key is the literal string, the value the
// movement); a Return is NSTextMovementReturn, and a Tab, a click elsewhere or the window closing
// is not a submit.
static void ak_field_end_editing(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id note)
    {
    NSNumber* mv = [(NSNotification*)note userInfo][@"NSTextMovement"];
    if (!mv || [mv integerValue] != NSTextMovementReturn)
        return;
    NSTextField* tf = [(NSNotification*)note object];
    int tag = (int)[tf tag], handle = tag / 1000, node = tag % 1000;
    if (g_field_submit)
        g_field_submit(handle, node); // fire the neutral field's onSubmit
    }
/* The rigs' editing-end: post the notification the text system posts, carrying the movement it
 * would carry.  This is how the GATE reaches the delegate path at all -- a posted key event is
 * dequeued by the driver before AppKit can route it to the field, so the neutral key path is what
 * a posted Return exercises, and this is the other one.  movement is an NSTextMovement:
 * NSTextMovementReturn (0x10) is a submit, NSTextMovementTab (0x11) and the rest are not. */
void ux_ak_test_end_editing(int handle, int node, int movement)
    {
    if (node < 0 || node >= UX_MAXN)
        return;
    NSTextField* tf = (NSTextField*)g_ctl[handle][node];
    if (!tf)
        return;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSControlTextDidEndEditingNotification
                      object:tf
                    userInfo:@{@"NSTextMovement" : @(movement)}];
    }
static id ak_field_delegate(void)
    {
    if (g_field_delegate)
        return g_field_delegate;
    Class c = objc_allocateClassPair([NSObject class], "UXFieldDelegate", 0);
    class_addMethod(c, sel_registerName("controlTextDidChange:"), (IMP)ak_field_changed, "v@:@");
    class_addMethod(c, sel_registerName("controlTextDidEndEditing:"), (IMP)ak_field_end_editing, "v@:@");
    objc_registerClassPair(c);
    g_field_delegate = [[c alloc] init];
    return g_field_delegate;
    }
void ux_ak_make_field(int handle, int node, int x, int y, int w, int h, char* buf, int cap, int secure)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= UX_MAXN)
        return;
    NSTextField* tf = secure ? [[NSSecureTextField alloc] initWithFrame:NSMakeRect(x, y, w, h)]
                             : [[NSTextField alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [tf setStringValue:(buf ? ak_ns(buf) : @"")];
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
    if (node < 0 || node >= UX_MAXN)
        return;
    NSView* v = g_ctl[handle][node];
    if (!v || ![v isKindOfClass:[NSTextField class]])
        return;
    [(NSTextField*)v setPlaceholderString:(text ? ak_ns(text) : @"")];
    }
// Push the buffer into the field IF it differs (so app setText propagates, but a normal repaint
// during editing — where buffer == field — leaves the caret alone).
void ux_ak_update_field(int handle, int node)
    {
    if (node < 0 || node >= UX_MAXN)
        return;
    NSTextField* tf = (NSTextField*)g_ctl[handle][node];
    char* buf = g_field_buf[handle][node];
    if (!tf || !buf)
        return;
    NSString* want = ak_ns(buf);
    if (![[tf stringValue] isEqualToString:want])
        [tf setStringValue:want];
    }
// A native label: a non-editable, borderless, transparent NSTextField (system font).
void ux_ak_make_label(int handle, int node, int x, int y, int w, int h, const char* text)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= UX_MAXN)
        return;
    NSTextField* tf = [NSTextField labelWithString:ak_ns(text)];
    [tf setFrame:NSMakeRect(x, y, w, h)];
    [tf setLineBreakMode:NSLineBreakByTruncatingTail]; // too narrow -> "…", not a hard clip
    [content addSubview:tf];
    g_ctl[handle][node] = tf;
    }
void ux_ak_set_label_text(int handle, int node, const char* text)
    {
    if (node < 0 || node >= UX_MAXN)
        return;
    NSView* v = g_ctl[handle][node];
    if (!v)
        return;
    NSString* want = ak_ns(text);
    if ([v isKindOfClass:[NSButton class]]) /* a button, check box or radio: its title */
        {
        NSButton* b = (NSButton*)v;
        if (![[b title] isEqualToString:want])
            [b setTitle:want];
        return;
        }
    NSTextField* tf = (NSTextField*)v;
    if ([tf isKindOfClass:[NSTextField class]] && ![[tf stringValue] isEqualToString:want])
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
    if (!content || node < 0 || node >= UX_MAXN)
        return;
    NSButton* b = [[NSButton alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [b setTitle:ak_ns(title)];
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
    if (!content || node < 0 || node >= UX_MAXN)
        return;
    NSString* t = ak_ns((title ? title : ""));
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
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
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
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
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
    if (node < 0 || node >= UX_MAXN)
        return;
    NSButton* b = (NSButton*)g_ctl[handle][node];
    if ([b isKindOfClass:[NSButton class]])
        [b setState:(on ? NSControlStateValueOn : NSControlStateValueOff)];
    }
void ux_ak_set_control_frame(int handle, int node, int x, int y, int w, int h)
    {
    if (node < 0 || node >= UX_MAXN)
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
    if (node < 0 || node >= UX_MAXN)
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
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
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
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
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
    if (handle < 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
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
    if (node < 0 || node >= UX_MAXN)
        return;
    NSView* v = g_ctl[handle][node];
    if (v)
        {
        /* Hiding an overlay leaves its region to the view BELOW: mark that area dirty so the map
         * under a just-hidden menu is recomposited (a stale dark panel is the client's report).
         * Showing marks the view itself. */
        if (on)
            {
            NSView* par = [v superview];
            if (par)
                {
                [par setNeedsDisplayInRect:[v frame]];
                }
            }
        [v setHidden:(on ? YES : NO)];
        if (!on)
            {
            [v setNeedsDisplay:YES];
            }
        }
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
    if (node < 0 || node >= UX_MAXN)
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
static ux_tbl_multi_fn g_tbl_drags = 0; /* whether a table's rows can be dragged out */
void ux_ak_set_table_drag_hook(void* fn)
    {
    g_tbl_drags = (ux_tbl_multi_fn)fn;
    }
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
/* A row dragged out: its first column, as the app's private row type. */
- (id<NSPasteboardWriting>)tableView:(NSTableView*)tv pasteboardWriterForRow:(NSInteger)row
    {
    if (!self.peer || !g_tbl_drags || !g_tbl_drags(self.peer) || !g_tbl_cell)
        return nil;
    NSPasteboardItem* it = [[NSPasteboardItem alloc] init];
    [it setString:ak_ns(g_tbl_cell(self.peer, (int)row, 0)) forType:AK_ROW_TYPE];
    return it;
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
    cv.textField.stringValue = s ? ak_ns(s) : @"";
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

static UXTableSource* g_tbl_src[UX_MAXW][UX_MAXN]; // ARC-strong: one datasource per table node

/* Whether every column of a table has an empty title: such a table shows no header row. */
static int ak_untitled(void* peer, int ncols)
    {
    for (int c = 0; c < ncols; c++)
        {
        const char* ti = (peer && g_tbl_title) ? g_tbl_title(peer, c) : "";
        if (ti && ti[0])
            return 0;
        }
    return 1;
    }
void ux_ak_make_table(int handle, int node, int x, int y, int w, int h, void* peer)
    {
    NSView* content = g_view[handle];
    if (!content || node < 0 || node >= UX_MAXN)
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
        [[tc headerCell] setStringValue:(ti ? ak_ns(ti) : @"")];
        int cw = (peer && g_tbl_width) ? g_tbl_width(peer, c) : 80;
        [tc setWidth:(cw > 0 ? cw : 80)];
        [tv addTableColumn:tc];
        }
    if (ak_untitled(peer, ncols))
        [tv setHeaderView:nil]; /* no titles: no header row */
    UXTableSource* src = [[UXTableSource alloc] init];
    src.peer = peer;
    [tv setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
    [tv setDraggingSourceOperationMask:NSDragOperationNone forLocal:NO];
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
    if (node < 0 || node >= UX_MAXN)
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
    if (node < 0 || node >= UX_MAXN)
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
static ux_ol_value_fn g_ol_dragtext = 0; /* what a dragged row carries, or NULL: it does not drag */
void ux_ak_set_outline_drag_hook(void* fn)
    {
    g_ol_dragtext = (ux_ol_value_fn)fn;
    }
void ux_ak_set_outline_hooks(void* children, void* child, void* expandable, void* value, void* didexpand)
    {
    g_ol_children = (ux_ol_children_fn)children;
    g_ol_child = (ux_ol_child_fn)child;
    g_ol_expandable = (ux_ol_expandable_fn)expandable;
    g_ol_value = (ux_ol_value_fn)value;
    g_ol_didexpand = (ux_ol_didexpand_fn)didexpand;
    }

@interface UXOutlineSource : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate, NSDraggingSource>
@property(assign, nonatomic) void* peer;
@property(assign, nonatomic) int handle; // the window, for drop points in its content's terms
@property(strong, nonatomic) NSString* dragText; // what the row being dragged carries
@end
/* An NSOutlineView that also starts a row's drag on the secondary button, as the primary one does:
   a right-drag (or control-drag) is how a connection is drawn from a row.  A right-click that does
   not move is the ordinary one. */
@interface UXNativeOutline : NSOutlineView
@end
@implementation UXNativeOutline
- (void)rightMouseDown:(NSEvent*)e
    {
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    NSInteger row = [self rowAtPoint:p];
    id item = row >= 0 ? [self itemAtRow:row] : nil;
    UXOutlineSource* src = (UXOutlineSource*)[self dataSource];
    id<NSPasteboardWriting> w = item ? [src outlineView:self pasteboardWriterForItem:item] : nil;
    if (!w)
        {
        [super rightMouseDown:e];
        return;
        }
    for (;;)
        {
        NSEvent* n = [[self window] nextEventMatchingMask:(NSEventMaskRightMouseDragged | NSEventMaskRightMouseUp)];
        if ([n type] == NSEventTypeRightMouseUp)
            {
            [super rightMouseDown:e];
            return;
            }
        NSPoint q = [self convertPoint:[n locationInWindow] fromView:nil];
        if ((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y) > 9)
            {
            NSRect r = [self rectOfRow:row];
            NSDraggingItem* di = [[NSDraggingItem alloc] initWithPasteboardWriter:w];
            NSBitmapImageRep* rep = [self bitmapImageRepForCachingDisplayInRect:r];
            [self cacheDisplayInRect:r toBitmapImageRep:rep];
            NSImage* im = [[NSImage alloc] initWithSize:r.size];
            [im addRepresentation:rep];
            [di setDraggingFrame:r contents:im];
            [self beginDraggingSessionWithItems:@[ di ] event:n source:src];
            return;
            }
        }
    }
@end
@implementation UXOutlineSource
/* The window content's point for a screen point. */
- (NSPoint)contentPoint:(NSPoint)screen
    {
    NSView* content = (self.handle > 0 && self.handle < UX_MAXW) ? g_view[self.handle] : nil;
    if (!content)
        return NSMakePoint(-1, -1);
    NSPoint wp = [[content window] convertPointFromScreen:screen];
    return [content convertPoint:wp fromView:nil];
    }
/* A row's drag begins: the app hears where, so a line can start at the row. */
- (void)began:(NSPoint)screen
    {
    if (!self.dragText || !g_itemHover)
        return;
    NSPoint p = [self contentPoint:screen];
    g_itemHover([self.dragText UTF8String], self.handle, (int)p.x, (int)p.y);
    }
- (void)ended
    {
    if (self.dragText && g_itemHover)
        g_itemHover([self.dragText UTF8String], self.handle, -1, -1);
    self.dragText = nil;
    }
- (void)outlineView:(NSOutlineView*)ov draggingSession:(NSDraggingSession*)s willBeginAtPoint:(NSPoint)p forItems:(NSArray*)items
    {
    [self began:p];
    }
- (void)outlineView:(NSOutlineView*)ov draggingSession:(NSDraggingSession*)s endedAtPoint:(NSPoint)p operation:(NSDragOperation)op
    {
    [self ended];
    }
/* As the source of a right-drag's session (UXNativeOutline). */
- (NSDragOperation)draggingSession:(NSDraggingSession*)s sourceOperationMaskForDraggingContext:(NSDraggingContext)c
    {
    return c == NSDraggingContextWithinApplication ? NSDragOperationCopy : NSDragOperationNone;
    }
- (void)draggingSession:(NSDraggingSession*)s willBeginAtPoint:(NSPoint)p
    {
    [self began:p];
    }
- (void)draggingSession:(NSDraggingSession*)s endedAtPoint:(NSPoint)p operation:(NSDragOperation)op
    {
    [self ended];
    }
/* A row dragged out: what the app says it carries, as the app's private row type. */
- (id<NSPasteboardWriting>)outlineView:(NSOutlineView*)ov pasteboardWriterForItem:(id)item
    {
    void* it = item ? [(NSValue*)item pointerValue] : NULL;
    const char* t = (self.peer && g_ol_dragtext && it) ? g_ol_dragtext(self.peer, it, 0) : NULL;
    if (!t)
        return nil;
    NSPasteboardItem* pb = [[NSPasteboardItem alloc] init];
    self.dragText = ak_ns(t);
    [pb setString:self.dragText forType:AK_ROW_TYPE];
    return pb;
    }
/* A row dragged over another: it is dropped ON that row (the row is highlighted), not between rows.
   The app hears it as a drop on the window at the row's point. */
- (NSDragOperation)outlineView:(NSOutlineView*)ov validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item proposedChildIndex:(NSInteger)index
    {
    if (![[info draggingPasteboard] stringForType:AK_ROW_TYPE] || !g_itemDrop)
        return NSDragOperationNone;
    NSInteger row = [ov rowAtPoint:[ov convertPoint:[info draggingLocation] fromView:nil]];
    id target = row >= 0 ? [ov itemAtRow:row] : nil;
    if (!target)
        return NSDragOperationNone;
    [ov setDropItem:target dropChildIndex:NSOutlineViewDropOnItemIndex];
    if (g_itemHover)
        {
        NSPoint p = [self contentPoint:[[ov window] convertPointToScreen:[info draggingLocation]]];
        g_itemHover([[[info draggingPasteboard] stringForType:AK_ROW_TYPE] UTF8String], self.handle, (int)p.x, (int)p.y);
        }
    return NSDragOperationCopy;
    }
- (BOOL)outlineView:(NSOutlineView*)ov acceptDrop:(id<NSDraggingInfo>)info item:(id)item childIndex:(NSInteger)index
    {
    NSString* t = [[info draggingPasteboard] stringForType:AK_ROW_TYPE];
    NSView* content = (self.handle > 0 && self.handle < UX_MAXW) ? g_view[self.handle] : nil;
    if (!t || !g_itemDrop || !content)
        return NO;
    NSPoint p = [content convertPoint:[info draggingLocation] fromView:nil];
    if (g_itemHover)
        g_itemHover([t UTF8String], self.handle, -1, -1);
    g_itemDrop([t UTF8String], self.handle, (int)p.x, (int)p.y);
    return YES;
    }
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
    return s ? ak_ns(s) : @"";
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

static UXOutlineSource* g_ol_src[UX_MAXW][UX_MAXN];

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
        g_tb_build_labels[ident] = ak_ns((label ? label : ""));
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
    for (int n = 0; n < UX_MAXN; n++)
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
    if (!content || node < 0 || node >= UX_MAXN)
        return;
    NSScrollView* sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [sv setHasVerticalScroller:YES];
    [sv setBorderType:NSBezelBorder];
    NSOutlineView* ov = [[UXNativeOutline alloc] initWithFrame:[[sv contentView] bounds]];
    [ov setAllowsMultipleSelection:((peer && g_tbl_multi && g_tbl_multi(peer)) ? YES : NO)];
    int ncols = (peer && g_tbl_cols) ? g_tbl_cols(peer) : 0;
    if (ncols <= 0)
        ncols = 1;
    NSTableColumn* first = nil;
    for (int c = 0; c < ncols; c++)
        {
        NSTableColumn* tc = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%d", c]];
        const char* ti = (peer && g_tbl_title) ? g_tbl_title(peer, c) : "";
        [[tc headerCell] setStringValue:(ti ? ak_ns(ti) : @"")];
        int cw = (peer && g_tbl_width) ? g_tbl_width(peer, c) : 120;
        [tc setWidth:(cw > 0 ? cw : 120)];
        [ov addTableColumn:tc];
        if (c == 0)
            first = tc;
        }
    [ov setOutlineTableColumn:first]; // the column that carries the disclosure triangles + indent
    if (ak_untitled(peer, ncols))
        [ov setHeaderView:nil]; /* no titles: no header row */
    UXOutlineSource* src = [[UXOutlineSource alloc] init];
    src.peer = peer;
    src.handle = handle;
    [ov setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
    [ov setDraggingSourceOperationMask:NSDragOperationNone forLocal:NO];
    [ov registerForDraggedTypes:@[ AK_ROW_TYPE ]];
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
    if (node < 0 || node >= UX_MAXN)
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
    if (!content || node < 0 || node >= UX_MAXN)
        return;
    NSScrollView* nsv = [[NSScrollView alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    [nsv setHasVerticalScroller:YES];
    /* Hide the bar when the whole page fits, the way the browser's `overflow: auto` does -- a
     * panel whose content is shorter than it should not wear a scrollbar. */
    [nsv setAutohidesScrollers:YES];
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
    if (node < 0 || node >= UX_MAXN)
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
    if (node < 0 || node >= UX_MAXN)
        return 0;
    NSScrollView* nsv = (NSScrollView*)g_ctl[handle][node];
    if (![nsv isKindOfClass:[NSScrollView class]])
        return 0;
    return (int)[[nsv contentView] bounds].origin.y;
    }

/* Re-parent a native control into the DOCUMENT view of the scroll view it sits inside, so it
 * scrolls and clips with the scroll instead of staying put over it.  The control was created as a
 * flat child of the content view with an absolute (content-view) frame; `ax,ay` is that absolute
 * origin, converted here into the document view's coordinates (the clip offset, the bezel and the
 * flip are all the shim's to get right).  setFrame 0 leaves the frame alone, for a control AppKit
 * tracks natively (an autoresize mask) -- re-setting it every pass would fight the live track.
 * A control already in the right document view is left where it is. */
static int g_akReparentN = 0; // how many controls this pass has moved (ux_ak_reparent_count)
void ux_ak_reparent_to_scroll(int handle, int node, int scrollNode, int ax, int ay, int aw, int ah, int setFrame)
    {
    NSView* ctl = g_ctl[handle][node];
    NSScrollView* sv = (NSScrollView*)g_ctl[handle][scrollNode];
    NSView* content = g_view[handle];
    if (!ctl || !sv || !content || ![sv isKindOfClass:[NSScrollView class]])
        return;
    NSView* doc = [sv documentView];
    if (!doc)
        return;
    if ([ctl superview] != doc)
        {
        [ctl removeFromSuperview];
        [doc addSubview:ctl];
        g_akReparentN = g_akReparentN + 1;
        }
    if (setFrame)
        {
        NSPoint p = [content convertPoint:NSMakePoint(ax, ay) toView:doc];
        [ctl setFrame:NSMakeRect(p.x, p.y, aw, ah)];
        }
    }
/* How many controls the re-parent pass has moved into a scroll document, cumulatively -- a gate
 * asserts it went up, which is the one thing a picture cannot show. */
int ux_ak_reparent_count(void)
    {
    return g_akReparentN;
    }

/* A rounded panel.  The scroll view becomes layer-backed so its layer can clip to the rounding
 * (content AND scroller), with an optional 1px edge that follows it; the scroller is inset by the
 * radius top and bottom so its track runs between the corners rather than into them.  A radius of
 * 0 with no edge restores the plain bezelled scroll view.  Applied on every realise, so a change of
 * radius or colour takes effect at the next display. */
void ux_ak_scroll_style(int handle, int node, int radius, int rgb)
    {
    if (node < 0 || node >= UX_MAXN)
        return;
    NSScrollView* nsv = (NSScrollView*)g_ctl[handle][node];
    if (![nsv isKindOfClass:[NSScrollView class]])
        return;
    if (radius <= 0 && rgb < 0)
        {
        if ([nsv wantsLayer])
            {
            nsv.layer.cornerRadius = 0;
            nsv.layer.borderWidth = 0;
            [nsv setScrollerInsets:NSEdgeInsetsMake(0, 0, 0, 0)];
            [nsv setBorderType:NSBezelBorder];
            }
        return;
        }
    [nsv setBorderType:NSNoBorder]; /* the bezel is square; the layer draws the edge instead */
    [nsv setWantsLayer:YES];
    nsv.layer.cornerRadius = radius;
    nsv.layer.masksToBounds = YES;
    if (rgb >= 0)
        {
        nsv.layer.borderWidth = 1;
        nsv.layer.borderColor = [[NSColor colorWithRed:((rgb >> 16) & 255) / 255.0
                                                 green:((rgb >> 8) & 255) / 255.0
                                                  blue:(rgb & 255) / 255.0
                                                 alpha:1.0] CGColor];
        }
    else
        {
        nsv.layer.borderWidth = 0;
        }
    [nsv setScrollerInsets:NSEdgeInsetsMake(radius, 0, radius, 0)];
    }
/* For a gate: the radius and edge width a native scroll view actually carries, or -1 for none. */
int ux_ak_scroll_corner(int handle, int node)
    {
    if (node < 0 || node >= UX_MAXN)
        return -1;
    NSScrollView* nsv = (NSScrollView*)g_ctl[handle][node];
    if (![nsv isKindOfClass:[NSScrollView class]] || ![nsv wantsLayer])
        return -1;
    return (int)nsv.layer.cornerRadius * 100 + (int)nsv.layer.borderWidth;
    }

void ux_ak_scroll_reload(int handle, int node, int contentH)
    {
    if (node < 0 || node >= UX_MAXN)
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
    /* any button: a drag that began with the secondary one (a connection drawn by right-drag)
     * is followed the same way, and its release ends it */
    NSEvent* e = [NSApp nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp |
                                               NSEventMaskRightMouseDragged | NSEventMaskRightMouseUp |
                                               NSEventMaskOtherMouseDragged | NSEventMaskOtherMouseUp)
                                    untilDate:[NSDate distantFuture]
                                       inMode:NSEventTrackingRunLoopMode
                                      dequeue:YES];
    if (!e || [e type] == NSEventTypeLeftMouseUp || [e type] == NSEventTypeRightMouseUp || [e type] == NSEventTypeOtherMouseUp)
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
    NSArray* ls = [ak_ns(lines) componentsSeparatedByString:@"|"];
    [a setMessageText:[ls count] > 0 ? ls[0] : @""];
    if ([ls count] > 1)
        {
        NSRange r = NSMakeRange(1, [ls count] - 1);
        [a setInformativeText:[[ls subarrayWithRange:r] componentsJoinedByString:@"\n"]];
        }
    NSArray* bs = [ak_ns(buttons) componentsSeparatedByString:@"|"];
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
// The alpha at a pixel, on its own.  ux_ak_pixel drops it (a cleared pixel and a black one both read
// as 0,0,0 through the components), so a test that has to tell "emptied" from "painted black" asks
// this instead.
int ux_ak_pixel_alpha(int handle, int x, int y)
    {
    if (!g_lastRep)
        return -1;
    NSColor* c = [g_lastRep colorAtX:x y:y];
    return (int)([c alphaComponent] * 255 + 0.5);
    }

/* For tests: the node whose native control a click at (x, y) in window `handle` reaches, by AppKit's
 * own hit test, or -1 (none: the content view, a shield, or nothing). */
int ux_ak_test_hit(int handle, int x, int y)
    {
    if (handle <= 0 || handle >= UX_MAXW || !g_view[handle])
        return -1;
    NSView* content = [g_win[handle] contentView];
    NSPoint p = [g_view[handle] convertPoint:NSMakePoint(x, y) toView:content];
    NSView* hit = [content hitTest:[content convertPoint:p toView:[content superview]]];
    for (NSView* v = hit; v; v = [v superview])
        for (int n = 0; n < UX_MAXN; n++)
            if (g_ctl[handle][n] == v)
                return n;
    return -1;
    }

/* The smallest the window's content may be dragged to. */
void ux_ak_window_set_min_size(int handle, int w, int h)
    {
    if (handle <= 0 || handle >= UX_MAXW || !g_win[handle])
        return;
    [g_win[handle] setContentMinSize:NSMakeSize(w, h)];
    }

/* For tests: a table row dropped on window `handle` at (x, y), delivered as a real drop is. */
int ux_ak_test_drop_item(int handle, const char* text, int x, int y)
    {
    if (handle <= 0 || handle >= UX_MAXW || !g_view[handle] || !g_itemDrop)
        return 0;
    g_itemDrop(text, handle, x, y);
    return 1;
    }

/* For tests: what a drag of `row` out of the table at `node` carries, into buf (empty if the table
   does not drag its rows), and whether window `handle` takes that as a drop.  1 = both. */
int ux_ak_test_row_drag(int handle, int node, int row, char* buf, int n)
    {
    if (n > 0)
        buf[0] = 0;
    if (handle <= 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
        return 0;
    NSScrollView* sv = (NSScrollView*)g_ctl[handle][node];
    if (![sv isKindOfClass:[NSScrollView class]])
        return 0;
    NSTableView* tv = (NSTableView*)[sv documentView];
    id<NSPasteboardWriting> w = [[tv dataSource] tableView:tv pasteboardWriterForRow:row];
    if (!w)
        return 0;
    NSString* t = [(NSPasteboardItem*)w stringForType:AK_ROW_TYPE];
    if (t && n > 0)
        snprintf(buf, (size_t)n, "%s", [t UTF8String]);
    return (t && [[g_view[handle] registeredDraggedTypes] containsObject:AK_ROW_TYPE]) ? 1 : 0;
    }

/* ---- context menus ------------------------------------------------------------------------- */
/* A pop-up NSMenu, modal: popUpMenuPositioningItem returns once the menu closes, and the item's
   action has recorded which it was.  For tests, ux_ak_test_menu_pick makes the next pop-up answer
   that index at once (and keep its titles to read back) instead of showing anything. */
@interface UXPopTarget : NSObject
@property(assign, nonatomic) int picked;
- (void)pick:(id)sender;
@end
@implementation UXPopTarget
- (void)pick:(id)sender
    {
    self.picked = (int)[(NSMenuItem*)sender tag];
    }
@end
static int g_menuTestPick = -2; /* -2: show the menu; otherwise the answer */
static char g_menuTestTitles[512];
void ux_ak_test_menu_pick(int i)
    {
    g_menuTestPick = i;
    }
const char* ux_ak_test_menu_titles(void)
    {
    return g_menuTestTitles;
    }
int ux_ak_menu_popup(int handle, const char** titles, const int* flags, int n, int x, int y)
    {
    if (handle <= 0 || handle >= UX_MAXW || !g_view[handle] || n <= 0)
        return -1;
    if (g_menuTestPick != -2)
        {
        int at = 0;
        g_menuTestTitles[0] = 0;
        for (int i = 0; i < n && at < (int)sizeof(g_menuTestTitles) - 2; i++)
            at += snprintf(g_menuTestTitles + at, sizeof(g_menuTestTitles) - (size_t)at, "%s%s",
                           i ? "|" : "", (flags[i] & 1) ? "-" : titles[i]);
        int p = g_menuTestPick;
        g_menuTestPick = -2;
        return p;
        }
    NSMenu* m = [[NSMenu alloc] initWithTitle:@""];
    [m setAutoenablesItems:NO];
    UXPopTarget* t = [[UXPopTarget alloc] init];
    t.picked = -1;
    for (int i = 0; i < n; i++)
        {
        if (flags[i] & 1)
            {
            [m addItem:[NSMenuItem separatorItem]];
            continue;
            }
        NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:ak_ns(titles[i]) action:@selector(pick:) keyEquivalent:@""];
        [it setTarget:t];
        [it setTag:i];
        [it setEnabled:(flags[i] & 2) ? NO : YES];
        [m addItem:it];
        }
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(x, y) inView:g_view[handle]];
    return t.picked;
    }

/* For tests: a row dragged over window `handle` at (x, y), or gone with (-1, -1). */
int ux_ak_test_hover_item(int handle, const char* text, int x, int y)
    {
    if (handle <= 0 || handle >= UX_MAXW || !g_view[handle] || !g_itemHover)
        return 0;
    g_itemHover(text, handle, x, y);
    return 1;
    }

/* The item of the outline at `node` under window point (x, y) of window `handle`, or NULL. */
void* ux_ak_outline_item_at(int handle, int node, int x, int y)
    {
    if (handle <= 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN || !g_view[handle])
        return NULL;
    NSScrollView* sv = (NSScrollView*)g_ctl[handle][node];
    if (![sv isKindOfClass:[NSScrollView class]] || [sv isHidden])
        return NULL;
    NSOutlineView* ov = (NSOutlineView*)[sv documentView];
    if (![ov isKindOfClass:[NSOutlineView class]])
        return NULL;
    NSPoint p = [ov convertPoint:NSMakePoint(x, y) fromView:g_view[handle]];
    if (!NSPointInRect(p, [ov bounds]) || !NSPointInRect([sv convertPoint:NSMakePoint(x, y) fromView:g_view[handle]], [sv bounds]))
        return NULL;
    NSInteger row = [ov rowAtPoint:p];
    id it = row >= 0 ? [ov itemAtRow:row] : nil;
    return it ? [(NSValue*)it pointerValue] : NULL;
    }
/* For tests: what a drag of `item` out of the outline at `node` carries, into buf; 1 if it drags and
   the outline takes such a row as a drop. */
int ux_ak_test_outline_drag(int handle, int node, void* item, char* buf, int n)
    {
    if (n > 0)
        buf[0] = 0;
    if (handle <= 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN)
        return 0;
    NSScrollView* sv = (NSScrollView*)g_ctl[handle][node];
    if (![sv isKindOfClass:[NSScrollView class]])
        return 0;
    NSOutlineView* ov = (NSOutlineView*)[sv documentView];
    id<NSPasteboardWriting> w = [(UXOutlineSource*)[ov dataSource] outlineView:ov pasteboardWriterForItem:[NSValue valueWithPointer:item]];
    if (!w)
        return 0;
    NSString* t = [(NSPasteboardItem*)w stringForType:AK_ROW_TYPE];
    if (t && n > 0)
        snprintf(buf, (size_t)n, "%s", [t UTF8String]);
    return (t && [[ov registeredDraggedTypes] containsObject:AK_ROW_TYPE]) ? 1 : 0;
    }

/* ---- a connection's line above everything in a window -------------------------------------- */
/* Native controls sit above whatever a window's content draws, so a line drawn there passes under
   them.  This one is drawn in a clear child window laid over the content, which takes no clicks. */
@interface UXLineView : NSView
@property(assign, nonatomic) NSPoint a;
@property(assign, nonatomic) NSPoint b;
@property(assign, nonatomic) NSRect hot;
@end
@implementation UXLineView
- (BOOL)isFlipped
    {
    return YES;
    }
- (void)drawRect:(NSRect)dirty
    {
    [[NSColor clearColor] set];
    NSRectFill(dirty);
    NSColor* c = [NSColor colorWithCalibratedRed:0.15 green:0.45 blue:0.95 alpha:1.0];
    [c set];
    if (self.hot.size.width > 0 && self.hot.size.height > 0)
        {
        NSBezierPath* f = [NSBezierPath bezierPathWithRect:NSInsetRect(self.hot, -1, -1)];
        [f setLineWidth:2];
        [f stroke];
        }
    /* the S-curve a connection is drawn with: it leaves one end and meets the other level, the
       control points pulled out sideways by half the distance across (and at least 30 points) */
    CGFloat dx = self.b.x - self.a.x;
    CGFloat k = fabs(dx) / 2 > 30 ? fabs(dx) / 2 : 30;
    CGFloat dir = dx < 0 ? -1 : 1;
    NSBezierPath* l = [NSBezierPath bezierPath];
    [l moveToPoint:self.a];
    [l curveToPoint:self.b controlPoint1:NSMakePoint(self.a.x + dir * k, self.a.y)
                         controlPoint2:NSMakePoint(self.b.x - dir * k, self.b.y)];
    [l setLineWidth:2];
    [l stroke];
    NSRect dot = NSMakeRect(self.b.x - 3, self.b.y - 3, 6, 6);
    [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
    }
@end
static NSWindow* g_lineWin[UX_MAXW];
void ux_ak_window_line(int handle, int on, int x0, int y0, int x1, int y1, int hx, int hy, int hw, int hh)
    {
    if (handle <= 0 || handle >= UX_MAXW || !g_view[handle])
        return;
    NSView* content = g_view[handle];
    NSWindow* parent = [content window];
    if (!on)
        {
        if (g_lineWin[handle])
            {
            [parent removeChildWindow:g_lineWin[handle]];
            [g_lineWin[handle] orderOut:nil];
            }
        return;
        }
    NSRect sr = [parent convertRectToScreen:[content convertRect:[content bounds] toView:nil]];
    if (!g_lineWin[handle])
        {
        NSWindow* w = [[NSWindow alloc] initWithContentRect:sr styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO];
        [w setOpaque:NO];
        [w setBackgroundColor:[NSColor clearColor]];
        [w setIgnoresMouseEvents:YES];
        [w setHasShadow:NO];
        [w setReleasedWhenClosed:NO];
        [w setContentView:[[UXLineView alloc] initWithFrame:NSMakeRect(0, 0, sr.size.width, sr.size.height)]];
        g_lineWin[handle] = w;
        }
    NSWindow* w = g_lineWin[handle];
    if (!NSEqualRects([w frame], sr))
        [w setFrame:sr display:NO];
    if ([w parentWindow] != parent)
        [parent addChildWindow:w ordered:NSWindowAbove];
    UXLineView* lv = (UXLineView*)[w contentView];
    [lv setFrame:NSMakeRect(0, 0, sr.size.width, sr.size.height)];
    lv.a = NSMakePoint(x0, y0);
    lv.b = NSMakePoint(x1, y1);
    lv.hot = NSMakeRect(hx, hy, hw, hh);
    [lv setNeedsDisplay:YES];
    [w orderFront:nil];
    [lv displayIfNeeded];
    }
/* For tests: whether window `handle`'s line is up, and its far end. */
int ux_ak_test_line(int handle, int* x1, int* y1)
    {
    if (handle <= 0 || handle >= UX_MAXW || !g_lineWin[handle] || ![g_lineWin[handle] isVisible])
        return 0;
    UXLineView* lv = (UXLineView*)[g_lineWin[handle] contentView];
    *x1 = (int)lv.b.x;
    *y1 = (int)lv.b.y;
    return 1;
    }

/* For tests: the text a native button, check box, radio button or label shows, into buf. */
int ux_ak_test_control_text(int handle, int node, char* buf, int n)
    {
    if (n > 0)
        buf[0] = 0;
    if (handle <= 0 || handle >= UX_MAXW || node < 0 || node >= UX_MAXN || !g_ctl[handle][node])
        return 0;
    NSView* v = g_ctl[handle][node];
    NSString* s = [v isKindOfClass:[NSButton class]] ? [(NSButton*)v title]
                : [v isKindOfClass:[NSTextField class]] ? [(NSTextField*)v stringValue] : nil;
    if (!s)
        return 0;
    snprintf(buf, (size_t)n, "%s", [s UTF8String]);
    return 1;
    }
