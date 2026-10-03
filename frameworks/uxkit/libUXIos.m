// libUXIos.m — the UIKit shim under UXIosDriver (sibling of libUXAppKit.m).
//
// The run-loop model is the settled B + A (spikes/ios-loop): UIKit owns the
// main thread's loop — xtc's main() enters ux_ios_shell_run() (which IS
// UIApplicationMain) and the registered entry runs from didFinishLaunching.
// Everything here happens on the main thread; nothing blocks.
//
// A UX "window" is a container UIView inside the one UIWindow (iOS is a
// single-window world; the z-order is subview order).  Each holds a
// UXDrawView, whose drawRect: is the paint seam — it binds a CGContext and
// calls the registered content callback, which walks the neutral tree and
// comes back through the ux_ios_* drawing ops.  Native controls (real
// UIButton/UILabel) overlay it, keyed [handle][node] exactly as the mac shim
// keys g_ctl, and a control's target-action fires the registered
// control-fire callback with (handle, node) — a notification, not a click.
//
// Headless proof rig: ux_ios_render() renders a window's whole hierarchy
// (draw view AND native controls) into a bitmap, synchronously;
// ux_ios_pixel() reads it back — the cacheDisplayInRect analogue.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <dlfcn.h>
#include "ux_posix_fs.h" // listDir / delete / rename / copy for the drawn file panel

#define UXIOS_MAXW 64

typedef void (*ux_entry_fn)(void);
typedef void (*ux_content_fn)(int handle, int wx, int wy, int ww, int wh, void* ud);
typedef void (*ux_fire_fn)(int handle, int node);

static ux_entry_fn gEntry;
static ux_fire_fn gFire;
static UIWindow* gWindow;         // the one real UIWindow
static UIView* gSafeRoot;         // pinned to the safe area — windows live HERE
static UIView* gWin[UXIOS_MAXW];  // handle -> container view
static UIView* gDraw[UXIOS_MAXW]; // handle -> its UXDrawView
static ux_content_fn gContent[UXIOS_MAXW];
static void* gContentUd[UXIOS_MAXW];
static UIView* gCtl[UXIOS_MAXW][256]; // [handle][node] -> native control
static int gNextH = 1;
static int gLive = 0;     // the §10 counter (windows)
static CGContextRef gCtx; // the CGContext of the draw in flight

// ── registration (called from xtc, before/at start) ─────────────────────────
void ux_ios_set_entry(void* fn)
    {
    gEntry = (ux_entry_fn)fn;
    }
// The frame clock (everyTurn).  iOS owns the loop, so the driver answers true and arms this
// repeating timer on the main run loop instead; fn runs on the UI thread, outside any draw.
static void (*g_ios_turn_fn)(void) = NULL;
static NSTimer* g_ios_turn_timer = nil;
void ux_ios_set_turn_hook(void* fn, int ms)
    {
    if (g_ios_turn_timer != nil)
        {
        [g_ios_turn_timer invalidate];
        g_ios_turn_timer = nil;
        }
    g_ios_turn_fn = (void (*)(void))fn;
    if (g_ios_turn_fn == NULL)
        {
        return;
        }
    double secs = ms > 0 ? (double)ms / 1000.0 : (1.0 / 60.0);
    g_ios_turn_timer = [NSTimer scheduledTimerWithTimeInterval:secs
                                                       repeats:YES
                                                         block:^(NSTimer* t) {
                                                           (void)t;
                                                           if (g_ios_turn_fn)
                                                               {
                                                               g_ios_turn_fn();
                                                               }
                                                         }];
    }
void ux_ios_set_control_fire(void* fn)
    {
    gFire = (ux_fire_fn)fn;
    }
void ux_ios_quit(int rc)
    {
    dispatch_async(dispatch_get_main_queue(), ^{
      exit(rc);
    });
    }

// ── the draw view ───────────────────────────────────────────────────────────
@interface UXDrawView : UIView
@property(nonatomic) int handle;
@end
// Touches on the drawn content -> UXKit's mouse events (UXTouch.xc): phase 0 down, 1 move, 2 up,
// 3 cancelled; x/y in the window's content coordinates.  Native controls on top take their own.
typedef void (*ux_touch_fn)(void*, int, int, int);
static ux_touch_fn gTouch;
void ux_ios_set_touch(void* fn)
    {
    gTouch = (ux_touch_fn)fn;
    }
@implementation UXDrawView
- (void)touchPhase:(int)phase touches:(NSSet<UITouch*>*)touches
    {
    UITouch* t = touches.anyObject;
    if (!t || !gTouch || !gContentUd[self.handle])
        return;
    CGPoint p = [t locationInView:self];
    gTouch(gContentUd[self.handle], phase, (int)p.x, (int)p.y);
    }
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)e
    {
    [self touchPhase:0 touches:touches];
    }
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)e
    {
    [self touchPhase:1 touches:touches];
    }
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)e
    {
    [self touchPhase:2 touches:touches];
    }
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)e
    {
    [self touchPhase:3 touches:touches];
    }
- (void)drawRect:(CGRect)dirty
    {
    if (!gContent[self.handle])
        return;
    gCtx = UIGraphicsGetCurrentContext();
    CGRect b = self.bounds;
    gContent[self.handle](self.handle, 0, 0, (int)b.size.width, (int)b.size.height,
                          gContentUd[self.handle]);
    gCtx = NULL;
    }
@end

// ── target-action: a native control fired ───────────────────────────────────
@interface UXCtlTarget : NSObject
@end
static UXCtlTarget* gTarget;
@implementation UXCtlTarget
- (void)fired:(UIButton*)b
    {
    if (gFire)
        gFire((int)(b.tag >> 8), (int)(b.tag & 0xFF)); // tag packs (handle, node)
    }
@end

// ── boot / windows ──────────────────────────────────────────────────────────
/* a real filled disc (the app-drawn radio's ring and dot) */
void ux_ios_circle(int cx, int cy, int r, int cr, int cg, int cb)
    {
    if (!gCtx)
        return;
    CGContextSetRGBFillColor(gCtx, cr / 255.0, cg / 255.0, cb / 255.0, 1.0);
    CGContextFillEllipseInRect(gCtx, CGRectMake(cx - r, cy - r, 2 * r, 2 * r));
    }

/* subtree clipping for the draw walk (the scroll viewport) */
void ux_ios_clip(int x, int y, int w, int h)
    {
    if (!gCtx)
        return;
    CGContextSaveGState(gCtx);
    CGContextClipToRect(gCtx, CGRectMake(x, y, w, h));
    }
void ux_ios_clip_round(int x, int y, int w, int h, int r)
    {
    if (!gCtx)
        return;
    CGContextSaveGState(gCtx);
    if (w <= 0 || h <= 0)
        {
        CGContextClipToRect(gCtx, CGRectZero);
        return;
        }
    CGFloat rr = r * 2 > w ? w / 2.0 : r * 2 > h ? h / 2.0 : r;
    if (rr <= 0)
        {
        CGContextClipToRect(gCtx, CGRectMake(x, y, w, h));
        return;
        }
    CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(x, y, w, h), rr, rr, NULL);
    CGContextAddPath(gCtx, path);
    CGContextClip(gCtx);
    CGPathRelease(path);
    }
void ux_ios_clip_end(void)
    {
    if (gCtx)
        CGContextRestoreGState(gCtx);
    }

int ux_ios_boot(int* w, int* h)
    {
    // Post-shell (the usual case: boot runs from the posted entry), the
    // USABLE screen is the safe-area container; pre-shell callers get the
    // raw screen and windows still land safely — the container clamps them.
    if (gSafeRoot && gSafeRoot.bounds.size.width > 0)
        {
        *w = (int)gSafeRoot.bounds.size.width;
        *h = (int)gSafeRoot.bounds.size.height;
        return 1;
        }
    CGRect s = UIScreen.mainScreen.bounds;
    *w = (int)s.size.width;
    *h = (int)s.size.height;
    return 1;
    }
int ux_ios_form_factor(void)
    {
    // 2 = tablet, 3 = phone — the UX_FORM_* registry's words, decided by idiom.
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 2 : 3;
    }
int ux_ios_orientation(void)
    {
    CGSize s = UIScreen.mainScreen.bounds.size;
    return s.width > s.height ? 2 /* UX_ORIENT_LANDSCAPE */ : 1 /* UX_ORIENT_PORTRAIT */;
    }
int ux_ios_window_create(int x, int y, int w, int h)
    {
    if (gNextH >= UXIOS_MAXW)
        return 0;
    int hh = gNextH++;
    UIView* v = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, h)];
    v.backgroundColor = UIColor.whiteColor;
    UXDrawView* d = [[UXDrawView alloc] initWithFrame:v.bounds];
    d.handle = hh;
    d.opaque = NO;
    d.contentMode = UIViewContentModeRedraw;
    [v addSubview:d];
    gWin[hh] = v;
    gDraw[hh] = d;
    gLive++;
    return hh;
    }
void ux_ios_window_set_content(int handle, void* fn, void* ud)
    {
    gContent[handle] = (ux_content_fn)fn;
    gContentUd[handle] = ud;
    }
void ux_ios_window_open(int handle, int x, int y, int w, int h)
    {
    UIView* v = gWin[handle];
    if (!v)
        return;
    v.frame = CGRectMake(x, y, w, h);
    gDraw[handle].frame = v.bounds;
    // safe-area coordinates: (0,0) is below the notch, above the home bar
    [(gSafeRoot ?: gWindow.rootViewController.view) addSubview:v];
    }
void ux_ios_window_front(int handle)
    {
    UIView* v = gWin[handle];
    if (v)
        [v.superview bringSubviewToFront:v];
    }
static void navWindowClosed(int handle);
void ux_ios_window_close(int handle)
    {
    UIView* v = gWin[handle];
    if (!v)
        return;
    navWindowClosed(handle);
    [v removeFromSuperview];
    for (int n = 0; n < 256; n++)
        gCtl[handle][n] = nil;
    gWin[handle] = nil;
    gDraw[handle] = nil;
    gContent[handle] = NULL;
    gLive--;
    }
void ux_ios_window_invalidate(int handle)
    {
    [gDraw[handle] setNeedsDisplay];
    }
void ux_ios_content_geometry(int handle, int* w, int* h)
    {
    UIView* v = gWin[handle];
    if (v)
        {
        *w = (int)v.bounds.size.width;
        *h = (int)v.bounds.size.height;
        }
    else
        {
        *w = 0;
        *h = 0;
        }
    }
/* The window's content as it is on screen, region (x, y, w, h) of its container view, into out as
 * w * h opaque 0xAARRGGBB words: the container and every subview -- the draw view (with the GL frame
 * painted into it), the native controls -- rendered by UIKit at 1x (the window's point size), over
 * the window's background colour. */
int ux_ios_window_snapshot(int handle, int x, int y, int w, int h, uint32_t* out)
    {
    UIView* v = (handle > 0 && handle < UXIOS_MAXW) ? gWin[handle] : nil;
    if (!v || w <= 0 || h <= 0 || !out)
        return 0;
    __block int ok = 0;
    @autoreleasepool
        {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(out, w, h, 8, w * 4, cs,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(cs);
        if (ctx)
            {
            UIColor* bg = v.window.backgroundColor ?: (v.backgroundColor ?: [UIColor whiteColor]);
            CGContextSetFillColorWithColor(ctx, bg.CGColor);
            CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
            /* UIKit draws y-down: flip the bitmap context, then shift the region to its origin */
            CGContextTranslateCTM(ctx, 0, h);
            CGContextScaleCTM(ctx, 1, -1);
            UIGraphicsPushContext(ctx);
            ok = [v drawViewHierarchyInRect:CGRectMake(-x, -y, v.bounds.size.width, v.bounds.size.height)
                         afterScreenUpdates:YES] ? 1 : 0;
            UIGraphicsPopContext();
            CGContextRelease(ctx);
            for (int i = 0; i < w * h; i++)
                out[i] |= 0xFF000000u; /* opaque: painted over the background */
            }
        }
    return ok;
    }
int ux_ios_native_count(void)
    {
    return gLive;
    }

// ── native value controls: the mac shim's list, iOS idioms ──────────────────
typedef void (*ux_value_fn)(int handle, int node, int value);
static ux_value_fn gValueChanged;
void ux_ios_set_value_changed(void* fn)
    {
    gValueChanged = (ux_value_fn)fn;
    }

@interface UXValueTarget : NSObject
@end
static UXValueTarget* gValueTarget;
static UXValueTarget* valueTarget(void)
    {
    if (!gValueTarget)
        gValueTarget = [UXValueTarget new];
    return gValueTarget;
    }
@implementation UXValueTarget
- (void)changed:(UIControl*)c
    {
    if (!gValueChanged)
        return;
    int v = 0;
    if ([c isKindOfClass:UISwitch.class])
        v = ((UISwitch*)c).on ? 1 : 0;
    else if ([c isKindOfClass:UISlider.class])
        v = (int)lroundf(((UISlider*)c).value);
    else if ([c isKindOfClass:UIStepper.class])
        v = (int)lround(((UIStepper*)c).value);
    else if ([c isKindOfClass:UISegmentedControl.class])
        v = (int)((UISegmentedControl*)c).selectedSegmentIndex;
    gValueChanged((int)(c.tag >> 8), (int)(c.tag & 0xFF), v);
    }
@end
static void wireValue(UIControl* c, int handle, int node)
    {
    c.tag = (handle << 8) | node;
    [c addTarget:valueTarget()
                  action:@selector(changed:)
        forControlEvents:UIControlEventValueChanged];
    }

// ── native controls (buttons + labels tonight; the rest follow the mac list) ─
int ux_ios_has_control(int handle, int node)
    {
    return gCtl[handle][node] != nil;
    }
void ux_ios_make_button(int handle, int node, int x, int y, int w, int h, const char* title)
    {
    UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
    // The FILLED configuration: still entirely native, and it looks like a
    // button rather than bare tinted text (the system default since iOS 7,
    // which reads poorly in a docs portrait and on a busy canvas alike).
    if (@available(iOS 15.0, *))
        {
        UIButtonConfiguration* cfg = [UIButtonConfiguration filledButtonConfiguration];
        cfg.title = [NSString stringWithUTF8String:title];
        b.configuration = cfg;
        }
    b.frame = CGRectMake(x, y, w, h);
    [b setTitle:[NSString stringWithUTF8String:title] forState:UIControlStateNormal];
    b.tag = (handle << 8) | node;
    if (!gTarget)
        gTarget = [UXCtlTarget new];
    [b addTarget:gTarget action:@selector(fired:) forControlEvents:UIControlEventTouchUpInside];
    [gWin[handle] addSubview:b];
    gCtl[handle][node] = b;
    }
void ux_ios_make_label(int handle, int node, int x, int y, int w, int h, const char* text)
    {
    UILabel* l = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, h)];
    l.text = [NSString stringWithUTF8String:text];
    l.font = [UIFont systemFontOfSize:13];
    [gWin[handle] addSubview:l];
    gCtl[handle][node] = l;
    }
void ux_ios_set_control_frame(int handle, int node, int x, int y, int w, int h)
    {
    gCtl[handle][node].frame = CGRectMake(x, y, w, h);
    }
void ux_ios_set_control_enabled(int handle, int node, int on)
    {
    UIView* c = gCtl[handle][node];
    if ([c isKindOfClass:UIControl.class])
        ((UIControl*)c).enabled = on != 0;
    }
void ux_ios_set_control_hidden(int handle, int node, int on)
    {
    gCtl[handle][node].hidden = on != 0;
    }

// The iOS toggle idiom: a UISwitch with its label beside it, in one wrapper
// view (one gCtl slot per node, as everywhere).  The switch rides at the
// LEFT so the layout matches the app-drawn checkbox it replaces.
void ux_ios_make_switch(int handle, int node, int x, int y, int w, int h,
                        const char* title, int on)
    {
    UIView* wrap = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, h)];
    UISwitch* sw = [UISwitch new];
    sw.on = on != 0;
    CGFloat sh = sw.frame.size.height;
    sw.frame = CGRectMake(0, (h - sh) / 2, sw.frame.size.width, sh);
    wireValue(sw, handle, node);
    UILabel* l = [[UILabel alloc] initWithFrame:
                                      CGRectMake(sw.frame.size.width + 8, 0, w - sw.frame.size.width - 8, h)];
    l.text = [NSString stringWithUTF8String:title];
    l.font = [UIFont systemFontOfSize:14];
    [wrap addSubview:sw];
    [wrap addSubview:l];
    [gWin[handle] addSubview:wrap];
    gCtl[handle][node] = wrap;
    }
void ux_ios_set_switch(int handle, int node, int on)
    {
    for (UIView* sub in gCtl[handle][node].subviews)
        if ([sub isKindOfClass:UISwitch.class])
            {
            ((UISwitch*)sub).on = on != 0;
            return;
            }
    }

void ux_ios_make_slider(int handle, int node, int x, int y, int w, int h,
                        int lo, int hi, int val)
    {
    UISlider* s = [[UISlider alloc] initWithFrame:CGRectMake(x, y, w, h)];
    s.minimumValue = lo;
    s.maximumValue = hi;
    s.value = val;
    wireValue(s, handle, node);
    [gWin[handle] addSubview:s];
    gCtl[handle][node] = s;
    }
void ux_ios_set_slider_value(int handle, int node, int val)
    {
    UIView* c = gCtl[handle][node];
    if ([c isKindOfClass:UISlider.class])
        ((UISlider*)c).value = val;
    }

void ux_ios_make_stepper(int handle, int node, int x, int y, int w, int h,
                         int lo, int hi, int step, int wraps, int val)
    {
    UIStepper* s = [UIStepper new];
    CGRect f = s.frame;
    s.frame = CGRectMake(x + (w - f.size.width) / 2, y + (h - f.size.height) / 2,
                         f.size.width, f.size.height);
    s.minimumValue = lo;
    s.maximumValue = hi;
    s.stepValue = step > 0 ? step : 1;
    s.wraps = wraps != 0;
    s.value = val;
    wireValue(s, handle, node);
    [gWin[handle] addSubview:s];
    gCtl[handle][node] = s;
    }
void ux_ios_set_stepper_value(int handle, int node, int val)
    {
    UIView* c = gCtl[handle][node];
    if ([c isKindOfClass:UIStepper.class])
        ((UIStepper*)c).value = val;
    }

void ux_ios_make_progress(int handle, int node, int x, int y, int w, int h, int mille)
    {
    UIProgressView* p = [[UIProgressView alloc]
        initWithProgressViewStyle:UIProgressViewStyleDefault];
    p.frame = CGRectMake(x, y + h / 2 - 2, w, 4);
    p.progress = mille / 1000.0f;
    [gWin[handle] addSubview:p];
    gCtl[handle][node] = p;
    }
void ux_ios_set_progress(int handle, int node, int mille, int indeterminate)
    {
    UIView* c = gCtl[handle][node];
    if ([c isKindOfClass:UIProgressView.class])
        ((UIProgressView*)c).progress = mille / 1000.0f;
    }

void ux_ios_make_segmented(int handle, int node, int x, int y, int w, int h, int nseg)
    {
    UISegmentedControl* s = [[UISegmentedControl alloc] initWithItems:@[]];
    for (int i = 0; i < nseg; i++)
        [s insertSegmentWithTitle:@"" atIndex:i animated:NO];
    s.frame = CGRectMake(x, y, w, h);
    wireValue(s, handle, node);
    [gWin[handle] addSubview:s];
    gCtl[handle][node] = s;
    }
void ux_ios_seg_set_label(int handle, int node, int seg, const char* label)
    {
    UIView* c = gCtl[handle][node];
    if ([c isKindOfClass:UISegmentedControl.class])
        [(UISegmentedControl*)c setTitle:[NSString stringWithUTF8String:label]
                       forSegmentAtIndex:seg];
    }
void ux_ios_seg_select(int handle, int node, int seg)
    {
    UIView* c = gCtl[handle][node];
    if ([c isKindOfClass:UISegmentedControl.class])
        ((UISegmentedControl*)c).selectedSegmentIndex = seg;
    }

// The native text field: real UITextField, real keyboard, real selection.
// Every edit syncs the app's buffer FIRST, then reports through the field
// hook — so the neutral UXTextField's text() is already truthful when its
// onChange fires (the mac shim's contract, verbatim).
typedef void (*ux_field_fn)(int handle, int node);
static ux_field_fn gFieldChanged;
void ux_ios_set_field_hooks(void* fn)
    {
    gFieldChanged = (ux_field_fn)fn;
    }
// ...and the other announcement: Return.  UIControlEventEditingDidEndOnExit is that key alone
// (the Return/done key ending editing), so no movement test is needed.
static ux_field_fn gFieldSubmit;
void ux_ios_set_field_submit_hooks(void* fn)
    {
    gFieldSubmit = (ux_field_fn)fn;
    }
static char* gFieldBuf[UXIOS_MAXW * 256];
static int gFieldCap[UXIOS_MAXW * 256];

@interface UXFieldTarget : NSObject
@end
static UXFieldTarget* gFieldTarget;
@implementation UXFieldTarget
- (void)edited:(UITextField*)tf
    {
    int handle = (int)(tf.tag >> 8), node = (int)(tf.tag & 0xFF);
    char* buf = gFieldBuf[handle * 256 + node];
    int cap = gFieldCap[handle * 256 + node];
    if (buf && cap > 0)
        {
        const char* t = tf.text.UTF8String ?: "";
        strlcpy(buf, t, cap);
        }
    if (gFieldChanged)
        gFieldChanged(handle, node);
    }
- (void)submitted:(UITextField*)tf
    {
    int handle = (int)(tf.tag >> 8), node = (int)(tf.tag & 0xFF);
    // The text is synced by the editing-changed path per keystroke; this is the Return alone.
    if (gFieldSubmit)
        gFieldSubmit(handle, node);
    }
@end
void ux_ios_make_field(int handle, int node, int x, int y, int w, int h,
                       char* buf, int cap, int secure)
    {
    UITextField* tf = [[UITextField alloc] initWithFrame:CGRectMake(x, y, w, h)];
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.font = [UIFont systemFontOfSize:14];
    tf.secureTextEntry = secure != 0;
    if (buf)
        tf.text = [NSString stringWithUTF8String:buf];
    tf.tag = (handle << 8) | node;
    gFieldBuf[handle * 256 + node] = buf;
    gFieldCap[handle * 256 + node] = cap;
    if (!gFieldTarget)
        gFieldTarget = [UXFieldTarget new];
    [tf addTarget:gFieldTarget
                  action:@selector(edited:)
        forControlEvents:UIControlEventEditingChanged];
    [tf addTarget:gFieldTarget
                  action:@selector(submitted:)
        forControlEvents:UIControlEventEditingDidEndOnExit];
    [gWin[handle] addSubview:tf];
    gCtl[handle][node] = tf;
    }
void ux_ios_update_field(int handle, int node)
    {
    UIView* c = gCtl[handle][node];
    char* buf = gFieldBuf[handle * 256 + node];
    if ([c isKindOfClass:UITextField.class] && buf)
        ((UITextField*)c).text = [NSString stringWithUTF8String:buf];
    }

// The popup: a UIButton whose UIMenu is the item list (the iOS pull-down
// idiom, 14+).  Each pick reports through the value seam with its index.
static NSMutableArray* gPopupItems[UXIOS_MAXW * 256];
static void popupRebuild(UIButton* b, int handle, int node, int selected)
    {
    NSMutableArray* items = gPopupItems[handle * 256 + node];
    NSMutableArray* actions = [NSMutableArray array];
    for (int i = 0; i < (int)items.count; i++)
        {
        UIAction* a = [UIAction actionWithTitle:items[i]
                                          image:nil
                                     identifier:nil
                                        handler:^(UIAction* act) {
                                          if (gValueChanged)
                                              gValueChanged(handle, node, i);
                                        }];
        if (i == selected)
            a.state = UIMenuElementStateOn;
        [actions addObject:a];
        }
    b.menu = [UIMenu menuWithChildren:actions];
    b.showsMenuAsPrimaryAction = YES;
    if (@available(iOS 15.0, *))
        b.changesSelectionAsPrimaryAction = YES;
    if (selected >= 0 && selected < (int)items.count)
        [b setTitle:items[selected] forState:UIControlStateNormal];
    }
void ux_ios_make_popup(int handle, int node, int x, int y, int w, int h)
    {
    UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 15.0, *))
        {
        // GRAY, not tinted: the platform's pull-down idiom is the neutral
        // capsule with tinted text — the tinted wash read as a highlighted state
        UIButtonConfiguration* cfg = [UIButtonConfiguration grayButtonConfiguration];
        b.configuration = cfg;
        }
    b.frame = CGRectMake(x, y, w, h);
    b.tag = (handle << 8) | node;
    gPopupItems[handle * 256 + node] = [NSMutableArray array];
    [gWin[handle] addSubview:b];
    gCtl[handle][node] = b;
    }
void ux_ios_popup_add_item(int handle, int node, const char* title)
    {
    [gPopupItems[handle * 256 + node] addObject:[NSString stringWithUTF8String:title]];
    popupRebuild((UIButton*)gCtl[handle][node], handle, node, -1);
    }
void ux_ios_popup_select(int handle, int node, int i)
    {
    popupRebuild((UIButton*)gCtl[handle][node], handle, node, i);
    }

// Tests: a full native tap at window-local (x, y) — the control under the point
// fires through the REAL target-action machinery (a UIButton fires on touch-up).
void ux_ios_post_click(int handle, int x, int y)
    {
    UIView* v = gWin[handle];
    if (!v)
        return;
    for (int n = 0; n < 256; n++)
        {
        UIView* c = gCtl[handle][n];
        if (c && !c.hidden && CGRectContainsPoint(c.frame, CGPointMake(x, y)))
            {
            if ([c isKindOfClass:UIButton.class])
                [(UIButton*)c sendActionsForControlEvents:UIControlEventTouchUpInside];
            return;
            }
        }
    }

// Tests: schedule a native tap through the main loop — the ios-loop gate's
// self-injection, same discipline as the spike's three timed taps.
void ux_ios_test_tap_later(int handle, int x, int y, int ms)
    {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     ux_ios_post_click(handle, x, y);
                   });
    }
// Tests: a watchdog so a wedged run FAILS rather than hangs.
/* Off the main thread, so a test wedged ON it (a nested run loop that never ends, a deadlock) is
 * still ended: a watchdog on the main queue would wait behind the very block that wedged. */
void ux_ios_test_watchdog(int ms, int rc)
    {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     fprintf(stderr, "watchdog: the test did not finish in %d ms\n", ms);
                     _exit(rc);
                   });
    }

// ── drawing ops (the CGContext of the draw in flight) ───────────────────────
static void setRGB(int r, int g, int b)
    {
    CGContextSetRGBFillColor(gCtx, r / 255.0, g / 255.0, b / 255.0, 1.0);
    }
/* alpha is the straight 0..255 value; CoreGraphics blends every fill and stroke source-over,
   so a translucent primitive composites with what is under it.  a == 255 is the opaque case. */
static void setRGBA(int r, int g, int b, int a)
    {
    CGContextSetRGBFillColor(gCtx, r / 255.0, g / 255.0, b / 255.0, a / 255.0);
    }
void ux_ios_fill(int x, int y, int w, int h, int r, int g, int b, int a)
    {
    if (!gCtx)
        return;
    setRGBA(r, g, b, a);
    CGContextFillRect(gCtx, CGRectMake(x, y, w, h));
    }
/* drawPixels: a bitmap region drawn into the draw in flight.  As on AppKit, the bitmap is wrapped in
 * a CGImage ONCE, cached by address, size and layout (an atlas is not re-wrapped per icon), and read
 * in place -- so the bytes must not change once drawn.  sRGB, straight alpha, top row first. */
#define IOS_PIXCACHE 8
static struct
    {
    const void* data;
    int w, h, format;
    CGImageRef img;
    } gPixCache[IOS_PIXCACHE];
static int gPixNext = 0;
static CGImageRef ios_pixels_image(const void* data, int w, int h, int format)
    {
    for (int i = 0; i < IOS_PIXCACHE; i++)
        if (gPixCache[i].img && gPixCache[i].data == data && gPixCache[i].w == w && gPixCache[i].h == h
            && gPixCache[i].format == format)
            return gPixCache[i].img;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, data, (size_t)w * h * 4, NULL);
    CGBitmapInfo bi = format == 1 ? (kCGImageAlphaFirst | kCGBitmapByteOrder32Little)
                                  : (kCGImageAlphaLast | kCGBitmapByteOrderDefault);
    CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs, bi, dp, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    if (!img)
        return NULL;
    int k = gPixNext;
    gPixNext = (gPixNext + 1) % IOS_PIXCACHE;
    if (gPixCache[k].img)
        CGImageRelease(gPixCache[k].img);
    gPixCache[k].data = data;
    gPixCache[k].w = w;
    gPixCache[k].h = h;
    gPixCache[k].format = format;
    gPixCache[k].img = img;
    return img;
    }
void ux_ios_draw_pixels(const void* data, int w, int h, int format, int sx, int sy, int sw, int sh,
                        int dx, int dy, int dw, int dh, int alpha)
    {
    if (!gCtx || !data || w <= 0 || h <= 0 || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0 || alpha <= 0)
        return;
    CGImageRef img = ios_pixels_image(data, w, h, format);
    if (!img)
        return;
    CGImageRef part = CGImageCreateWithImageInRect(img, CGRectMake(sx, sy, sw, sh));
    if (!part)
        return;
    CGContextSaveGState(gCtx);
    CGContextSetAlpha(gCtx, alpha >= 255 ? 1.0 : alpha / 255.0);
    CGContextSetInterpolationQuality(gCtx, kCGInterpolationHigh);
    /* UIKit's context is y-down and an image is drawn y-up: flip it about its destination. */
    CGContextTranslateCTM(gCtx, dx, dy + dh);
    CGContextScaleCTM(gCtx, 1, -1);
    CGContextDrawImage(gCtx, CGRectMake(0, 0, dw, dh), part);
    CGContextRestoreGState(gCtx);
    CGImageRelease(part);
    }
/* CLEAR: erase the rect whatever is under it, so a compositing layer starts empty.  A source-over
   fill at alpha 0 would paint nothing instead of emptying. */
void ux_ios_clear(int x, int y, int w, int h)
    {
    if (!gCtx)
        return;
    CGContextClearRect(gCtx, CGRectMake(x, y, w, h));
    }
void ux_ios_tri(int x0, int y0, int x1, int y1, int x2, int y2, int r, int g, int b)
    {
    if (!gCtx)
        return;
    setRGB(r, g, b);
    CGContextBeginPath(gCtx);
    CGContextMoveToPoint(gCtx, x0, y0);
    CGContextAddLineToPoint(gCtx, x1, y1);
    CGContextAddLineToPoint(gCtx, x2, y2);
    CGContextClosePath(gCtx);
    CGContextFillPath(gCtx);
    }
void ux_ios_poly(short* xy, int n, int r, int g, int b, int a)
    {
    if (!gCtx || n < 3)
        return;
    setRGBA(r, g, b, a);
    CGContextBeginPath(gCtx);
    CGContextMoveToPoint(gCtx, xy[0], xy[1]);
    for (int i = 1; i < n; i++)
        CGContextAddLineToPoint(gCtx, xy[i * 2], xy[i * 2 + 1]);
    CGContextClosePath(gCtx);
    CGContextFillPath(gCtx);
    }
static void drawString(const char* s, int x, int y, int r, int g, int b, int a, UIFont* font)
    {
    NSString* t = [NSString stringWithUTF8String:s];
    [t drawAtPoint:CGPointMake(x, y)
        withAttributes:@{NSFontAttributeName : font,
                         NSForegroundColorAttributeName :
                             [UIColor colorWithRed:r / 255.0
                                             green:g / 255.0
                                              blue:b / 255.0
                                             alpha:a / 255.0]}];
    }
void ux_ios_text(const char* s, int x, int y, int r, int g, int b, int a, int size)
    {
    if (!gCtx)
        return;
    drawString(s, x, y, r, g, b, a, [UIFont systemFontOfSize:size > 0 ? size : 13]);
    }
void ux_ios_text_font(const char* s, int x, int y, int r, int g, int b,
                      const char* family, int size, int bold, int italic)
    {
    if (!gCtx)
        return;
    CGFloat pt = size > 0 ? size : 13;
    UIFont* f = family && family[0] ? [UIFont fontWithName:[NSString stringWithUTF8String:family] size:pt] : nil;
    if (!f)
        f = bold ? [UIFont boldSystemFontOfSize:pt] : [UIFont systemFontOfSize:pt];
    drawString(s, x, y, r, g, b, 255, f);
    }
/* A font at a numeric CSS weight, through a font descriptor's weight trait so a named family is
   honoured and a family without the exact weight resolves to the nearest it has. */
static UIFont* ios_weighted_font(const char* family, CGFloat pt, int weight, int italic)
    {
    CGFloat w; /* UIFontWeight* on the CSS 100..900 scale */
    if (weight <= 100)      w = UIFontWeightThin;
    else if (weight <= 300) w = UIFontWeightLight;
    else if (weight <= 400) w = UIFontWeightRegular;
    else if (weight <= 500) w = UIFontWeightMedium;
    else if (weight <= 600) w = UIFontWeightSemibold;
    else if (weight <= 700) w = UIFontWeightBold;
    else if (weight <= 800) w = UIFontWeightHeavy;
    else                    w = UIFontWeightBlack;
    UIFontDescriptor* base = (family && family[0])
        ? [UIFontDescriptor fontDescriptorWithName:[NSString stringWithUTF8String:family] size:pt]
        : [UIFont systemFontOfSize:pt].fontDescriptor;
    UIFontDescriptor* d = [base fontDescriptorByAddingAttributes:
        @{UIFontDescriptorTraitsAttribute : @{UIFontWeightTrait : @(w)}}];
    if (italic)
        d = [d fontDescriptorWithSymbolicTraits:(d.symbolicTraits | UIFontDescriptorTraitItalic)];
    UIFont* f = [UIFont fontWithDescriptor:d size:pt];
    if (!f)
        f = [UIFont systemFontOfSize:pt weight:w];
    return f;
    }
void ux_ios_text_weight(const char* s, int x, int y, const char* family, int size,
                        int weight, int italic, int r, int g, int b, int a)
    {
    if (!gCtx)
        return;
    UIFont* f = ios_weighted_font(family, (CGFloat)(size > 0 ? size : 13), weight, italic);
    drawString(s, x, y, r, g, b, a, f);
    }
/* The width is in device points and may be fractional: CGContextSetLineWidth takes a CGFloat, so a
 * 1.536-pt border is exactly that.
 * dash/ndash/phase: the on/off run in device points and the offset into it (ndash 0 = solid); a
 * negative offset starts the run before its beginning, as lineDashOffset does. */
void ux_ios_stroke_path(int* ops, int n, double width, int startCap, int endCap, int join,
                        int* dash, int ndash, int phase, int r, int g, int b, int a)
    {
    if (!gCtx || n <= 0 || width <= 0.0)
        return;
    CGContextSetRGBStrokeColor(gCtx, r / 255.0, g / 255.0, b / 255.0, a / 255.0);
    CGContextSetLineWidth(gCtx, (CGFloat)width);
    /* join: 0 miter, 1 round, 2 bevel (UXJOIN_*) */
    CGContextSetLineJoin(gCtx, join == 0 ? kCGLineJoinMiter
                             : join == 2 ? kCGLineJoinBevel : kCGLineJoinRound);
    int cap = startCap > endCap ? startCap : endCap;
    CGContextSetLineCap(gCtx, cap == 1 ? kCGLineCapRound : (cap == 2 ? kCGLineCapSquare : kCGLineCapButt));
    if (ndash > 0)
        {
        CGFloat pat[8];
        int k = ndash > 8 ? 8 : ndash;
        for (int j = 0; j < k; j++)
            pat[j] = dash[j] > 0 ? (CGFloat)dash[j] : (CGFloat)1;
        CGContextSetLineDash(gCtx, (CGFloat)phase, pat, (size_t)k);
        }
    else
        {
        CGContextSetLineDash(gCtx, 0, NULL, 0);
        }
    CGContextBeginPath(gCtx);
    int i = 0, started = 0;
    CGFloat sx = 0, sy = 0;
    while (i < n)
        {
        int op = ops[i++];
        // MOVE
        if (op == 0 && i + 1 < n + 1)
            {
            sx = ops[i];
            sy = ops[i + 1];
            i += 2;
            CGContextMoveToPoint(gCtx, sx, sy);
            started = 1;
            }
        // LINE
        else if (op == 1 && i + 1 < n + 1)
            {
            if (!started)
                {
                sx = ops[i];
                sy = ops[i + 1];
                CGContextMoveToPoint(gCtx, sx, sy);
                started = 1;
                }
            else
                CGContextAddLineToPoint(gCtx, ops[i], ops[i + 1]);
            i += 2;
            }
        // CURVE
        else if (op == 2 && i + 5 < n + 1)
            {
            CGContextAddCurveToPoint(gCtx, ops[i], ops[i + 1], ops[i + 2], ops[i + 3], ops[i + 4], ops[i + 5]);
            i += 6;
            }
        // CLOSE
        else if (op == 3)
            {
            CGContextClosePath(gCtx);
            }
        else
            break;
        }
    CGContextStrokePath(gCtx);
    }

// ── measurement / time / settings (the driver's ambient surface) ────────────
int ux_ios_text_width(const char* s, int size)
    {
    NSString* t = [NSString stringWithUTF8String:s];
    CGSize sz = [t sizeWithAttributes:@{NSFontAttributeName : [UIFont systemFontOfSize:size > 0 ? size : 13]}];
    return (int)(sz.width + 0.5);
    }
int ux_ios_text_width_font(const char* s, const char* family, int size, int bold, int italic)
    {
    CGFloat pt = size > 0 ? size : 13;
    UIFont* f = family && family[0] ? [UIFont fontWithName:[NSString stringWithUTF8String:family] size:pt] : nil;
    if (!f)
        f = bold ? [UIFont boldSystemFontOfSize:pt] : [UIFont systemFontOfSize:pt];
    NSString* t = [NSString stringWithUTF8String:s];
    return (int)([t sizeWithAttributes:@{NSFontAttributeName : f}].width + 0.5);
    }
/* The measure at a NUMERIC weight, through the same face the drawing call builds. */
int ux_ios_text_width_weight(const char* s, const char* family, int size, int weight, int italic)
    {
    UIFont* f = ios_weighted_font(family, (CGFloat)(size > 0 ? size : 13), weight, italic);
    NSString* t = [NSString stringWithUTF8String:s];
    return (int)([t sizeWithAttributes:@{NSFontAttributeName : f}].width + 0.5);
    }
/* The FACE's ascent: the distance from the top of the line to the baseline. */
int ux_ios_text_ascent(const char* family, int size, int weight, int italic)
    {
    UIFont* f = ios_weighted_font(family, (CGFloat)(size > 0 ? size : 13), weight, italic);
    return (int)ceil(f.ascender);
    }
int ux_ios_now_ms(void)
    {
    return (int)(CACurrentMediaTime() * 1000.0) & 0x7FFFFFFF;
    }
void ux_ios_now_utc(int* out7)
    {
    NSDateComponents* c = [[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]
        componentsInTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]
                    fromDate:[NSDate date]];
    out7[0] = (int)c.year;
    out7[1] = (int)c.month;
    out7[2] = (int)c.day;
    out7[3] = (int)c.hour;
    out7[4] = (int)c.minute;
    out7[5] = (int)c.second;
    out7[6] = (int)(c.nanosecond / 1000);
    }
int ux_ios_local_offset_minutes(void)
    {
    return (int)([NSTimeZone.localTimeZone secondsFromGMT] / 60);
    }
int ux_ios_setting_get(const char* dom, const char* key, char* out, int cap)
    {
    NSUserDefaults* d = dom && dom[0]
                            ? [[NSUserDefaults alloc] initWithSuiteName:[NSString stringWithUTF8String:dom]]
                            : NSUserDefaults.standardUserDefaults;
    NSString* v = [d stringForKey:[NSString stringWithUTF8String:key]];
    if (!v)
        return 0;
    strlcpy(out, v.UTF8String, cap);
    return 1;
    }
int ux_ios_setting_set(const char* dom, const char* key, const char* val)
    {
    NSUserDefaults* d = dom && dom[0]
                            ? [[NSUserDefaults alloc] initWithSuiteName:[NSString stringWithUTF8String:dom]]
                            : NSUserDefaults.standardUserDefaults;
    [d setObject:[NSString stringWithUTF8String:val] forKey:[NSString stringWithUTF8String:key]];
    return 1;
    }
int ux_ios_setting_remove(const char* dom, const char* key)
    {
    NSUserDefaults* d = dom && dom[0]
                            ? [[NSUserDefaults alloc] initWithSuiteName:[NSString stringWithUTF8String:dom]]
                            : NSUserDefaults.standardUserDefaults;
    [d removeObjectForKey:[NSString stringWithUTF8String:key]];
    return 1;
    }

// ── the headless readback rig (cacheDisplayInRect's iOS analogue) ───────────
static unsigned char* gPix;
static int gPixW, gPixH;
static void navRenderBars(int handle, CGContextRef ctx); // the nav section, below
void ux_ios_render(int handle)
    {
    UIView* v = gWin[handle];
    if (!v)
        return;
    int w = (int)v.bounds.size.width, h = (int)v.bounds.size.height;
    free(gPix);
    gPix = calloc(w * h * 4, 1);
    gPixW = w;
    gPixH = h;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(gPix, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    // Flip: CGBitmapContext's origin is bottom-left; the layer renders top-down.
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, 1, -1);
    [v setNeedsLayout];
    [v layoutIfNeeded];
    [gDraw[handle] setNeedsDisplay];
    UIGraphicsPushContext(ctx);
    [v.layer renderInContext:ctx]; // the draw view AND the native controls
    navRenderBars(handle, ctx);   // and a native navigation bar over it, which lives beside it
    UIGraphicsPopContext();
    CGContextRelease(ctx);
    }
// Render an ARBITRARY view (the alert card) into the readback buffer.
static void iosRenderViewToPix(UIView* v)
    {
    [v setNeedsLayout];
    [v layoutIfNeeded];
    int w = (int)v.bounds.size.width, h = (int)v.bounds.size.height;
    if (w <= 0 || h <= 0)
        return;
    free(gPix);
    gPix = calloc(w * h * 4, 1);
    gPixW = w;
    gPixH = h;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(gPix, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, 1, -1);
    /* composite over white: the alert card's blur material is translucent */
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    UIGraphicsPushContext(ctx);
    [v.layer renderInContext:ctx];
    UIGraphicsPopContext();
    CGContextRelease(ctx);
    }

/* ── the modal alert: UIAlertController + a nested CFRunLoop ─────────────────
 * The sync-modal shape (the plan's promise for this driver): present the
 * controller, then spin the main run loop nested until an action fires —
 * alertRun's synchronous contract on a platform whose alerts are async by
 * design.  The rigs arm ux_ios_alert_auto first: after ~500ms the alert's
 * card is (optionally) rendered into the readback buffer, then dismissed as
 * cancel — headless gates and portraits, no human. */
static int gIosAlertResult, gIosAlertDone;
static int gIosAlertAutoMs, gIosAlertAutoShot;
void ux_ios_alert_auto(int ms, int shot)
    {
    gIosAlertAutoMs = ms;
    gIosAlertAutoShot = shot;
    }

int ux_ios_alert(int icon, const char* lines, const char* buttons, int defBtn)
    {
    NSArray* ls = [[NSString stringWithUTF8String:lines] componentsSeparatedByString:@"|"];
    NSString* title = ls.count ? ls[0] : @"";
    NSString* msg = ls.count > 1
                        ? [[ls subarrayWithRange:NSMakeRange(1, ls.count - 1)] componentsJoinedByString:@"\n"]
                        : nil;
    NSArray* bs = [[NSString stringWithUTF8String:buttons] componentsSeparatedByString:@"|"];
    if (!bs.count)
        return 1;
    UIAlertController* a = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    gIosAlertResult = (int)bs.count;
    gIosAlertDone = 0;
    for (NSUInteger i = 0; i < bs.count; i++)
        {
        /* last of several = the cancel role (bold, Esc/scrim) — the platform convention */
        UIAlertActionStyle st = (bs.count > 1 && i == bs.count - 1)
                                    ? UIAlertActionStyleCancel
                                    : UIAlertActionStyleDefault;
        int idx = (int)i + 1;
        [a addAction:[UIAlertAction actionWithTitle:bs[i]
                                              style:st
                                            handler:^(UIAlertAction* act) {
                                              gIosAlertResult = idx;
                                              gIosAlertDone = 1;
                                              CFRunLoopStop(CFRunLoopGetMain());
                                            }]];
        }
    if (defBtn >= 1 && defBtn <= (int)bs.count)
        a.preferredAction = a.actions[defBtn - 1];
    [gWindow.rootViewController presentViewController:a animated:NO completion:nil];
    if (gIosAlertAutoMs > 0)
        {
        int shot = gIosAlertAutoShot;
        int cancelIdx = (int)bs.count;
        long ms = gIosAlertAutoMs;
        gIosAlertAutoMs = 0;
        gIosAlertAutoShot = 0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
                         if (shot)
                             iosRenderViewToPix(a.view);
                         [a dismissViewControllerAnimated:NO
                                               completion:^{
                                                 gIosAlertResult = cancelIdx;
                                                 gIosAlertDone = 1;
                                                 CFRunLoopStop(CFRunLoopGetMain());
                                               }];
                       });
        }
    while (!gIosAlertDone)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    return gIosAlertResult;
    }

// ── GL: OpenGL ES 3, rendered offscreen, painted in the window's own 2-D pass ────────────────
// The one-surface model AppKit, Win32 and Android use.  Each GL view gets an EAGLContext (ES 3) and
// a framebuffer object at the view's PIXEL size (its points times the screen scale) with depth and
// stencil, bound as the renderer's default.  presentGL reads the frame back into a CGImage and
// has the window redrawn, and the draw walk paints the image where the view sits, in tree order,
// so a 2-D view after the GL view is drawn over it.  GL's rows run bottom-up and the drawing
// contexts here are top-down: drawing the image as read flips it once more, the right way up.
// The OpenGLES framework is opened at run time (no app links it), and EAGLContext is reached
// through the runtime, so nothing here names the deprecated API at compile time.
#define UXIOS_GL_MAX 8
typedef void (*igl_gen_fn)(int, unsigned*);
typedef void (*igl_bind_fn)(unsigned, unsigned);
typedef void (*igl_rbstorage_fn)(unsigned, unsigned, int, int);
typedef void (*igl_fbrb_fn)(unsigned, unsigned, unsigned, unsigned);
typedef void (*igl_viewport_fn)(int, int, int, int);
typedef void (*igl_readpixels_fn)(int, int, int, int, unsigned, unsigned, void*);
typedef void (*igl_del_fn)(int, const unsigned*);
typedef void (*igl_getint_fn)(unsigned, int*);
static void* gGlesLib;
static Class gEAGL;
static struct
    {
    void* view;
    id ctx;
    unsigned fbo, rbColor, rbDepth;
    int pw, ph;        /* the drawable, in pixels */
    CGImageRef img;    /* the last frame */
    int win;           /* the window it was last painted in (0: not yet) */
    } gGl[UXIOS_GL_MAX];
static int gGlCount;
static int gGlTestMax; /* tests: a lower GPU limit, to exercise the clamp */
void ux_ios_test_gl_max(int max)
    {
    gGlTestMax = max;
    }
static int iglLoad(void)
    {
    if (gEAGL)
        return 1;
    if (!gGlesLib)
        gGlesLib = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW);
    if (!gGlesLib)
        return 0;
    gEAGL = NSClassFromString(@"EAGLContext");
    return gEAGL != nil;
    }
static void iglCur(int i)
    {
    ((BOOL(*)(id, SEL, id))objc_msgSend)((id)gEAGL, @selector(setCurrentContext:), gGl[i].ctx);
    }
void* ux_ios_gl_proc(const char* name)
    {
    if (!iglLoad() || !name)
        return NULL;
    return dlsym(gGlesLib, name);
    }
/* a slot back to empty, through ARC: the context is an object, so no memset over it */
static void iglClear(int i, void* view)
    {
    gGl[i].ctx = nil;
    gGl[i].view = view;
    gGl[i].fbo = gGl[i].rbColor = gGl[i].rbDepth = 0;
    gGl[i].pw = gGl[i].ph = 0;
    gGl[i].img = NULL;
    gGl[i].win = 0;
    }
static int iglFind(void* view)
    {
    for (int i = 0; i < gGlCount; i++)
        if (gGl[i].view == view)
            return i;
    return -1;
    }
/* (re)make the framebuffer at w x h pixels, clamped to the GPU's limits keeping the aspect, and
 * set the viewport to it */
static void iglFramebuffer(int i, int w, int h)
    {
    igl_getint_fn gi = (igl_getint_fn)dlsym(gGlesLib, "glGetIntegerv");
    int maxRb = 0, maxVp[2] = {0, 0};
    gi(0x84E8 /* GL_MAX_RENDERBUFFER_SIZE */, &maxRb);
    gi(0x0D3A /* GL_MAX_VIEWPORT_DIMS */, maxVp);
    int lim = maxRb > 0 ? maxRb : 4096;
    if (maxVp[0] > 0 && maxVp[0] < lim) lim = maxVp[0];
    if (maxVp[1] > 0 && maxVp[1] < lim) lim = maxVp[1];
    if (gGlTestMax > 0 && gGlTestMax < lim) lim = gGlTestMax;
    if (w > lim || h > lim)
        {
        if (w >= h) { h = (int)((long)h * lim / w); w = lim; }
        else { w = (int)((long)w * lim / h); h = lim; }
        }
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    igl_gen_fn genFb = (igl_gen_fn)dlsym(gGlesLib, "glGenFramebuffers");
    igl_gen_fn genRb = (igl_gen_fn)dlsym(gGlesLib, "glGenRenderbuffers");
    igl_bind_fn bindFb = (igl_bind_fn)dlsym(gGlesLib, "glBindFramebuffer");
    igl_bind_fn bindRb = (igl_bind_fn)dlsym(gGlesLib, "glBindRenderbuffer");
    igl_rbstorage_fn st = (igl_rbstorage_fn)dlsym(gGlesLib, "glRenderbufferStorage");
    igl_fbrb_fn att = (igl_fbrb_fn)dlsym(gGlesLib, "glFramebufferRenderbuffer");
    igl_del_fn delFb = (igl_del_fn)dlsym(gGlesLib, "glDeleteFramebuffers");
    igl_del_fn delRb = (igl_del_fn)dlsym(gGlesLib, "glDeleteRenderbuffers");
    igl_viewport_fn vp = (igl_viewport_fn)dlsym(gGlesLib, "glViewport");
    if (gGl[i].fbo)
        {
        delFb(1, &gGl[i].fbo);
        delRb(1, &gGl[i].rbColor);
        delRb(1, &gGl[i].rbDepth);
        }
    genFb(1, &gGl[i].fbo);
    genRb(1, &gGl[i].rbColor);
    genRb(1, &gGl[i].rbDepth);
    bindRb(0x8D41, gGl[i].rbColor);
    st(0x8D41, 0x8058 /* GL_RGBA8 */, w, h);
    bindRb(0x8D41, gGl[i].rbDepth);
    st(0x8D41, 0x88F0 /* GL_DEPTH24_STENCIL8 */, w, h);
    bindFb(0x8D40, gGl[i].fbo);
    att(0x8D40, 0x8CE0, 0x8D41, gGl[i].rbColor);
    att(0x8D40, 0x821A, 0x8D41, gGl[i].rbDepth);
    vp(0, 0, w, h);
    gGl[i].pw = w;
    gGl[i].ph = h;
    }
void* ux_ios_gl_make(void* view, int w, int h)
    {
    if (!iglLoad())
        return NULL;
    int i = iglFind(view);
    if (i < 0)
        {
        if (gGlCount >= UXIOS_GL_MAX)
            return NULL;
        i = gGlCount++;
        iglClear(i, view);
        }
    if (!gGl[i].ctx)
        {
        gGl[i].ctx = ((id(*)(id, SEL, NSUInteger))objc_msgSend)([gEAGL alloc], @selector(initWithAPI:), 3);
        if (!gGl[i].ctx)
            return NULL;
        iglCur(i);
        CGFloat sc = UIScreen.mainScreen.scale;
        iglFramebuffer(i, (int)(w * sc + 0.5), (int)(h * sc + 0.5));
        }
    else
        iglCur(i);
    return (void*)(intptr_t)(i + 1); /* the opaque token, never the context */
    }
void ux_ios_gl_resize(void* view, int w, int h)
    {
    int i = iglFind(view);
    if (i < 0 || !gGl[i].ctx)
        return;
    iglCur(i);
    CGFloat sc = UIScreen.mainScreen.scale;
    iglFramebuffer(i, (int)(w * sc + 0.5), (int)(h * sc + 0.5));
    }
void ux_ios_gl_destroy(void* view)
    {
    int i = iglFind(view);
    if (i < 0 || !gGl[i].ctx)
        return;
    iglCur(i);
    igl_del_fn delFb = (igl_del_fn)dlsym(gGlesLib, "glDeleteFramebuffers");
    igl_del_fn delRb = (igl_del_fn)dlsym(gGlesLib, "glDeleteRenderbuffers");
    if (gGl[i].fbo)
        {
        delFb(1, &gGl[i].fbo);
        delRb(1, &gGl[i].rbColor);
        delRb(1, &gGl[i].rbDepth);
        }
    ((BOOL(*)(id, SEL, id))objc_msgSend)((id)gEAGL, @selector(setCurrentContext:), nil);
    if (gGl[i].img)
        CGImageRelease(gGl[i].img);
    iglClear(i, gGl[i].view); /* ARC releases the context, unbound first; the slot stays the view's */
    }
void ux_ios_gl_present(void* view)
    {
    int i = iglFind(view);
    if (i < 0 || !gGl[i].ctx)
        return;
    iglCur(i);
    int w = gGl[i].pw, h = gGl[i].ph;
    CFMutableDataRef data = CFDataCreateMutable(NULL, (CFIndex)w * h * 4);
    CFDataSetLength(data, (CFIndex)w * h * 4);
    ((igl_bind_fn)dlsym(gGlesLib, "glBindFramebuffer"))(0x8D40, gGl[i].fbo);
    ((igl_readpixels_fn)dlsym(gGlesLib, "glReadPixels"))(0, 0, w, h, 0x1908, 0x1401, CFDataGetMutableBytePtr(data));
    CGDataProviderRef dp = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs, kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast,
                                   dp, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(dp);
    CFRelease(data);
    if (gGl[i].img)
        CGImageRelease(gGl[i].img);
    gGl[i].img = img;
    for (int hw = 1; hw < UXIOS_MAXW; hw++)
        if (gDraw[hw] && (gGl[i].win == 0 || gGl[i].win == hw))
            [gDraw[hw] setNeedsDisplay];
    }
/* Paint a GL view's last frame where it sits, in the draw in flight.  1 if it drew. */
int ux_ios_gl_paint(void* view, int win, int x, int y, int w, int h)
    {
    int i = iglFind(view);
    if (i < 0 || !gGl[i].ctx || !gGl[i].img || !gCtx)
        return 0;
    gGl[i].win = win;
    CGContextSetInterpolationQuality(gCtx, kCGInterpolationLow);
    CGContextDrawImage(gCtx, CGRectMake(x, y, w, h), gGl[i].img);
    return 1;
    }
int ux_ios_test_gl_size(void* view, int* w, int* h)
    {
    int i = iglFind(view);
    if (i < 0)
        return 0;
    *w = gGl[i].pw;
    *h = gGl[i].ph;
    return 1;
    }

// ── the document picker: UIDocumentPickerViewController, modal through a nested run loop ──
// UXOpenPanel on iOS is the system's document picker, in import mode: the picked document (from
// the device or any file provider) is copied into the app's own tmp space, so the path that comes
// back reads with UXFileIO's plain fopen.  As with the alert, a nested CFRunLoop gives the async
// picker UXKit's synchronous contract.  (The string-type initializer, deprecated but current, keeps
// every app from having to link UniformTypeIdentifiers.)
@interface UXPickHost : NSObject <UIDocumentPickerDelegate>
@end
static UXPickHost* gPickHost;
static UIDocumentPickerViewController* gPicker;
static NSString* gPickedPath;
static int gPickDone;
@implementation UXPickHost
- (void)documentPicker:(UIDocumentPickerViewController*)c didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls
    {
    gPickedPath = urls.count ? urls[0].path : nil;
    gPickDone = 1;
    }
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)c
    {
    gPickedPath = nil;
    gPickDone = 1;
    }
@end
int ux_ios_file_open(char* out, int cap)
    {
    if (!gPickHost)
        gPickHost = [UXPickHost new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    gPicker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.item" ]
                                                                     inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    gPicker.delegate = gPickHost;
    gPicker.allowsMultipleSelection = NO;
    gPickDone = 0;
    gPickedPath = nil;
    [gWindow.rootViewController presentViewController:gPicker animated:NO completion:nil];
    while (!gPickDone)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    if (gPicker.presentingViewController)
        [gPicker dismissViewControllerAnimated:NO completion:nil];
    gPicker = nil;
    const char* u = gPickedPath.fileSystemRepresentation;
    if (!u || (int)strlen(u) + 1 > cap)
        return 0;
    memcpy(out, u, strlen(u) + 1);
    return 1;
    }
/* Tests (there is no driving another process's UI in the simulator): whether the picker is up,
 * and the picker's own delegate answers, exactly as UIKit sends them -- a pick of a file the test
 * made (UIKit hands an import-mode delegate its private copy's URL) or a cancel. */
int ux_ios_test_picker_shown(void)
    {
    return gPicker && gPicker.presentingViewController && gPicker.view.window ? 1 : 0;
    }
void ux_ios_test_picker_answer(const char* path)
    {
    if (!gPicker)
        return;
    if (path)
        [gPicker.delegate documentPicker:gPicker didPickDocumentsAtURLs:@[ [NSURL fileURLWithPath:@(path)] ]];
    else
        [gPicker.delegate documentPickerWasCancelled:gPicker];
    }

// ── the save panel: the export picker, then the bytes copied on after each write ──
// UXSavePanel on iOS asks for the destination first: the system's export picker, given a staging file
// in the app's tmp space under the default name, lets the user choose where it goes (the device, any
// file provider).  The staging path is what comes back, so UXFileIO writes it as usual; each write that
// lands is then copied on to the chosen document (ux_ios_file_written, through UXKit's file sink).
@interface UXExportHost : NSObject <UIDocumentPickerDelegate>
@end
static UXExportHost* gExportHost;
static UIDocumentPickerViewController* gExporter;
static NSMutableDictionary<NSString*, NSURL*>* gExports; // staging path -> the chosen document
static NSURL* gExportDest;
static int gExportDone;
@implementation UXExportHost
- (void)documentPicker:(UIDocumentPickerViewController*)c didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls
    {
    gExportDest = urls.count ? urls[0] : nil;
    gExportDone = 1;
    }
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)c
    {
    gExportDest = nil;
    gExportDone = 1;
    }
@end
static void uxPresentModally(UIViewController* vc, int* done);
int ux_ios_file_save(const char* defaultName, char* out, int cap)
    {
    if (!gExportHost)
        {
        gExportHost = [UXExportHost new];
        gExports = [NSMutableDictionary new];
        }
    NSString* name = defaultName && defaultName[0] ? @(defaultName) : @"untitled";
    name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString* dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"saved"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* staging = [dir stringByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:staging])
        [[NSData data] writeToFile:staging atomically:NO];
    gExporter = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ [NSURL fileURLWithPath:staging] ]
                                                                      asCopy:YES];
    gExporter.delegate = gExportHost;
    gExportDest = nil;
    uxPresentModally(gExporter, &gExportDone);
    gExporter = nil;
    const char* u = staging.fileSystemRepresentation;
    if (!gExportDest || (int)strlen(u) + 1 > cap)
        return 0;
    gExports[staging] = gExportDest;
    memcpy(out, u, strlen(u) + 1);
    return 1;
    }
/* After a write to a staging path lands: copy it on to the document the user chose.  1 if it got
 * there (or the path is an ordinary file of the app's), 0 if not. */
int ux_ios_file_written(const char* path)
    {
    NSURL* dest = gExports[@(path)];
    if (!dest)
        return 1;
    BOOL scoped = [dest startAccessingSecurityScopedResource];
    NSData* d = [NSData dataWithContentsOfFile:@(path)];
    BOOL ok = d && [d writeToURL:dest options:0 error:nil];
    if (scoped)
        [dest stopAccessingSecurityScopedResource];
    return ok ? 1 : 0;
    }
/* Tests: whether the export picker is up, which file it was given, and its delegate's answers as
 * UIKit sends them -- a destination chosen (a file URL the test names) or a cancel. */
int ux_ios_test_export_shown(void)
    {
    return gExporter && gExporter.presentingViewController && gExporter.view.window ? 1 : 0;
    }
void ux_ios_test_export_answer(const char* destPath)
    {
    if (!gExporter)
        return;
    if (destPath)
        [gExporter.delegate documentPicker:gExporter didPickDocumentsAtURLs:@[ [NSURL fileURLWithPath:@(destPath)] ]];
    else
        [gExporter.delegate documentPickerWasCancelled:gExporter];
    }

// ── the colour and font pickers: UIColorPickerViewController / UIFontPickerViewController ──
// Modal through a nested run loop, as the document picker.  The colour picker has no Cancel: closing
// it is the choice, so pickColor gives back whatever it holds then (the seed, if the user changed
// nothing).  The font picker chooses a family and, with faces shown, a face; it has no size, so the
// size is the one passed in.
@interface UXColorHost : NSObject <UIColorPickerViewControllerDelegate>
@end
@interface UXFontHost : NSObject <UIFontPickerViewControllerDelegate>
@end
/* A font picker whose selection a test can stand in for: the property is read-only in UIKit, and
 * the delegate reads it exactly as it does after a user's pick. */
@interface UXFontPicker : UIFontPickerViewController
@property(nonatomic, strong) UIFontDescriptor* testPick;
@end
@implementation UXFontPicker
- (UIFontDescriptor*)selectedFontDescriptor
    {
    return self.testPick ? self.testPick : [super selectedFontDescriptor];
    }
@end
static UXColorHost* gColorHost;
static UXFontHost* gFontHost;
static UIColorPickerViewController* gColorPicker;
static UXFontPicker* gFontPicker;
static UIFontDescriptor* gFontPicked;
static int gColorDone, gFontDone;
@implementation UXColorHost
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController*)c
    {
    gColorDone = 1;
    }
@end
@implementation UXFontHost
- (void)fontPickerViewControllerDidPickFont:(UIFontPickerViewController*)c
    {
    gFontPicked = c.selectedFontDescriptor;
    gFontDone = 1;
    }
- (void)fontPickerViewControllerDidCancel:(UIFontPickerViewController*)c
    {
    gFontPicked = nil;
    gFontDone = 1;
    }
@end
static void uxPresentModally(UIViewController* vc, int* done)
    {
    *done = 0;
    [gWindow.rootViewController presentViewController:vc animated:NO completion:nil];
    while (!*done)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    if (vc.presentingViewController)
        [vc dismissViewControllerAnimated:NO completion:nil];
    }
int ux_ios_pick_color(int r, int g, int b, int* outR, int* outG, int* outB)
    {
    if (!gColorHost)
        gColorHost = [UXColorHost new];
    gColorPicker = [UIColorPickerViewController new];
    gColorPicker.delegate = gColorHost;
    gColorPicker.supportsAlpha = NO;
    gColorPicker.selectedColor = [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1];
    uxPresentModally(gColorPicker, &gColorDone);
    CGFloat cr = 0, cg = 0, cb = 0, ca = 0;
    [gColorPicker.selectedColor getRed:&cr green:&cg blue:&cb alpha:&ca];
    gColorPicker = nil;
    *outR = (int)lround(fmin(fmax(cr, 0), 1) * 255);
    *outG = (int)lround(fmin(fmax(cg, 0), 1) * 255);
    *outB = (int)lround(fmin(fmax(cb, 0), 1) * 255);
    return 1;
    }
int ux_ios_pick_font(int inSize, char* outFamily, int cap, int* outSize, int* outBold, int* outItalic)
    {
    if (!gFontHost)
        gFontHost = [UXFontHost new];
    UIFontPickerViewControllerConfiguration* cfg = [UIFontPickerViewControllerConfiguration new];
    cfg.includeFaces = YES;
    gFontPicker = [[UXFontPicker alloc] initWithConfiguration:cfg];
    gFontPicker.delegate = gFontHost;
    gFontPicked = nil;
    uxPresentModally(gFontPicker, &gFontDone);
    gFontPicker = nil;
    if (!gFontPicked)
        return 0;
    UIFont* f = [UIFont fontWithDescriptor:gFontPicked size:inSize > 0 ? inSize : 12];
    const char* fam = f.familyName.UTF8String;
    if (!fam || (int)strlen(fam) + 1 > cap)
        return 0;
    memcpy(outFamily, fam, strlen(fam) + 1);
    UIFontDescriptorSymbolicTraits t = f.fontDescriptor.symbolicTraits;
    *outSize = inSize;
    *outBold = (t & UIFontDescriptorTraitBold) ? 1 : 0;
    *outItalic = (t & UIFontDescriptorTraitItalic) ? 1 : 0;
    return 1;
    }
/* Tests: whether each picker is up, and its own delegate's answers as UIKit sends them -- a colour
 * set in the picker then the picker closed; a font face picked (by PostScript name) or a cancel. */
int ux_ios_test_color_picker_shown(void)
    {
    return gColorPicker && gColorPicker.presentingViewController && gColorPicker.view.window ? 1 : 0;
    }
void ux_ios_test_color_picker_answer(int r, int g, int b)
    {
    if (!gColorPicker)
        return;
    gColorPicker.selectedColor = [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1];
    [gColorPicker.delegate colorPickerViewControllerDidFinish:gColorPicker];
    }
int ux_ios_test_font_picker_shown(void)
    {
    return gFontPicker && gFontPicker.presentingViewController && gFontPicker.view.window ? 1 : 0;
    }
void ux_ios_test_font_picker_answer(const char* postscriptName)
    {
    if (!gFontPicker)
        return;
    if (postscriptName)
        {
        gFontPicker.testPick = [UIFontDescriptor fontDescriptorWithName:@(postscriptName) size:0];
        [gFontPicker.delegate fontPickerViewControllerDidPickFont:gFontPicker];
        }
    else
        [gFontPicker.delegate fontPickerViewControllerDidCancel:gFontPicker];
    }

// Dump the last render as a PPM (the mac rig's ux_ak_dump_ppm, iOS edition) —
// the capture pipeline pulls these from the app sandbox.
int ux_ios_dump_ppm(const char* path)
    {
    if (!gPix)
        return 0;
    FILE* f = fopen(path, "wb");
    if (!f)
        return 0;
    fprintf(f, "P6\n%d %d\n255\n", gPixW, gPixH);
    for (int y = 0; y < gPixH; y++)
        for (int x = 0; x < gPixW; x++)
            {
            unsigned char* p = gPix + (y * gPixW + x) * 4;
            fwrite(p, 1, 3, f);
            }
    fclose(f);
    return 1;
    }
int ux_ios_pixel(int x, int y)
    {
    if (!gPix || x < 0 || y < 0 || x >= gPixW || y >= gPixH)
        return -1;
    unsigned char* p = gPix + (y * gPixW + x) * 4;
    return (p[0] << 16) | (p[1] << 8) | p[2];
    }

// ── the app's menus: a "more" button with a UIMenu ─────────────────────────────────────────────
// An iPhone or an iPad has no menu bar, so the app's menus (UXMenu) hang from a "⋯" button at the
// top right of the safe area, above every window: a UIMenu with a submenu per title, shown as the
// button's primary action.  The driver hands the menus over as one string (UXMenuEncode.xc); a
// pick comes back as (title, item), which the driver turns into the same UXEventMenuSelect a
// desktop's menu bar sends.  Checked and disabled states are kept here and the menu rebuilt.
typedef void (*menu_pick_fn)(int, int);
static menu_pick_fn gMenuPick;
static NSMutableArray<NSString*>* gMenuTitles;
static NSMutableArray<NSMutableArray<NSMutableDictionary*>*>* gMenuItems;
static UIButton* gMenuBtn;
void ux_ios_set_menu_pick(void* fn)
    {
    gMenuPick = (menu_pick_fn)fn;
    }
static void menuRebuild(void)
    {
    if (!gSafeRoot)
        return;
    if (gMenuTitles.count == 0)
        {
        gMenuBtn.hidden = YES;
        return;
        }
    if (!gMenuBtn)
        {
        gMenuBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [gMenuBtn setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
        gMenuBtn.showsMenuAsPrimaryAction = YES;
        gMenuBtn.accessibilityLabel = @"Menu";
        gMenuBtn.translatesAutoresizingMaskIntoConstraints = NO;
        UIView* host = gSafeRoot.superview;
        [host addSubview:gMenuBtn];
        [NSLayoutConstraint activateConstraints:@[
            [gMenuBtn.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:2],
            [gMenuBtn.trailingAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.trailingAnchor constant:-8],
            [gMenuBtn.widthAnchor constraintEqualToConstant:40],
            [gMenuBtn.heightAnchor constraintEqualToConstant:40],
        ]];
        }
    gMenuBtn.hidden = NO;
    [gMenuBtn.superview bringSubviewToFront:gMenuBtn];
    NSMutableArray<UIMenuElement*>* tops = [NSMutableArray new];
    for (NSUInteger t = 0; t < gMenuTitles.count; t++)
        {
        /* a separator splits the items into inline groups, which UIKit draws with a divider */
        NSMutableArray<UIMenuElement*>* groups = [NSMutableArray new];
        NSMutableArray<UIMenuElement*>* cur = [NSMutableArray new];
        NSArray* items = gMenuItems[t];
        for (NSUInteger j = 0; j < items.count; j++)
            {
            NSDictionary* it = items[j];
            if ([it[@"sep"] boolValue])
                {
                if (cur.count)
                    [groups addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:cur]];
                cur = [NSMutableArray new];
                continue;
                }
            int tt = (int)t, jj = (int)j;
            UIAction* a = [UIAction actionWithTitle:it[@"text"] image:nil identifier:nil handler:^(UIAction* x) {
                if (gMenuPick) gMenuPick(tt, jj);
            }];
            if ([it[@"checked"] boolValue]) a.state = UIMenuElementStateOn;
            if ([it[@"disabled"] boolValue]) a.attributes = UIMenuElementAttributesDisabled;
            [cur addObject:a];
            }
        if (cur.count)
            [groups addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:cur]];
        [tops addObject:[UIMenu menuWithTitle:gMenuTitles[t] children:groups]];
        }
    gMenuBtn.menu = [UIMenu menuWithTitle:@"" children:tops];
    }
void ux_ios_menu_set(const char* enc)
    {
    gMenuTitles = [NSMutableArray new];
    gMenuItems = [NSMutableArray new];
    NSString* all = [NSString stringWithUTF8String:enc ? enc : ""];
    for (NSString* group in [all componentsSeparatedByString:@"\x1e"])
        {
        if (group.length == 0)
            continue;
        NSArray<NSString*>* parts = [group componentsSeparatedByString:@"\x1f"];
        [gMenuTitles addObject:parts[0]];
        NSMutableArray* items = [NSMutableArray new];
        for (NSUInteger k = 1; k < parts.count; k++)
            {
            NSString* p = parts[k];
            NSMutableDictionary* it = [NSMutableDictionary new];
            if ([p isEqualToString:@"-"])
                it[@"sep"] = @YES;
            else if (p.length && [p characterAtIndex:0] == 1)
                { it[@"checked"] = @YES; it[@"text"] = [p substringFromIndex:1]; }
            else if (p.length && [p characterAtIndex:0] == 2)
                { it[@"disabled"] = @YES; it[@"text"] = [p substringFromIndex:1]; }
            else
                it[@"text"] = p;
            [items addObject:it];
            }
        [gMenuItems addObject:items];
        }
    menuRebuild();
    }
/* what: 0 checked, 1 enabled */
void ux_ios_menu_state(int t, int j, int what, int on)
    {
    if (t < 0 || t >= (int)gMenuItems.count || j < 0 || j >= (int)gMenuItems[t].count)
        return;
    NSMutableDictionary* it = gMenuItems[t][j];
    if (what == 0) it[@"checked"] = @(on != 0);
    else it[@"disabled"] = @(on == 0);
    menuRebuild();
    }
/* Tests: the button is up; the menu's titles; an item as the menu shows it (1 there, 2 checked,
 * 4 disabled); and a USER's pick (the action's own handler, as UIKit calls it). */
static UIAction* menuAction(int t, int j)
    {
    if (!gMenuBtn.menu || t < 0 || t >= (int)gMenuBtn.menu.children.count)
        return nil;
    UIMenu* top = (UIMenu*)gMenuBtn.menu.children[t];
    int k = 0;
    for (UIMenuElement* g in top.children)
        for (UIMenuElement* e in ((UIMenu*)g).children)
            {
            /* item ordinals count separators, which are not actions: skip their slots */
            while (k < (int)gMenuItems[t].count && [gMenuItems[t][k][@"sep"] boolValue]) k++;
            if (k == j) return (UIAction*)e;
            k++;
            }
    return nil;
    }
int ux_ios_test_menu_shown(void)
    {
    return gMenuBtn && !gMenuBtn.hidden && gMenuBtn.window ? (int)gMenuBtn.menu.children.count : 0;
    }
int ux_ios_test_menu_title_is(int t, const char* want)
    {
    if (!gMenuBtn.menu || t >= (int)gMenuBtn.menu.children.count) return 0;
    return [gMenuBtn.menu.children[t].title isEqualToString:[NSString stringWithUTF8String:want]];
    }
int ux_ios_test_menu_item(int t, int j)
    {
    UIAction* a = menuAction(t, j);
    if (!a) return 0;
    return 1 | (a.state == UIMenuElementStateOn ? 2 : 0) | ((a.attributes & UIMenuElementAttributesDisabled) ? 4 : 0);
    }
void ux_ios_test_menu_pick(int t, int j)
    {
    UIAction* a = menuAction(t, j);
    if (a && !(a.attributes & UIMenuElementAttributesDisabled) && gMenuPick)
        gMenuPick(t, j); /* exactly what the action's handler does */
    }

// ── the native table: UITableView ───────────────────────────────────────────────────────────
// A UXTableView realized as a real UITableView.  Like AppKit's NSTableView it holds no data: the
// row count and each cell's text come from the peer UXTableView through hooks (the datasource that
// feeds the drawn table).  A row is one cell with a label per UXKit column, at the columns' widths;
// the titles, if any, are the table's header view.  A selection the user taps goes back through the
// selectset hook; one the app makes is pushed in, muted so it does not echo.
typedef int (*tbl_rows_fn)(void*);
typedef const char* (*tbl_cell_fn)(void*, int, int);
typedef int (*tbl_cols_fn)(void*);
typedef const char* (*tbl_title_fn)(void*, int);
typedef int (*tbl_width_fn)(void*, int);
typedef int (*tbl_multi_fn)(void*);
typedef void (*tbl_selset_fn)(void*, int*, int);
typedef int (*tbl_rowint_fn)(void*, int);
typedef void (*tbl_toggle_fn)(void*, int);
static tbl_rowint_fn gTblLevel, gTblDisclosure;
static tbl_toggle_fn gTblToggle;
/* An OUTLINE is the same list: its flattened visible rows, each indented by its depth, with a
 * chevron for an item that can open.  A tap on the chevron opens or shuts it in the model. */
void ux_ios_set_outline_hooks(void* level, void* disclosure, void* toggle)
    {
    gTblLevel = (tbl_rowint_fn)level;
    gTblDisclosure = (tbl_rowint_fn)disclosure;
    gTblToggle = (tbl_toggle_fn)toggle;
    }
#define UX_TBL_INDENT 16
#define UX_TBL_CHEVRON 22
static tbl_rows_fn gTblRows;
static tbl_cell_fn gTblCell;
static tbl_cols_fn gTblCols;
static tbl_title_fn gTblTitle;
static tbl_width_fn gTblWidth;
static tbl_multi_fn gTblMulti;
static tbl_selset_fn gTblSelSet;
void ux_ios_set_table_hooks(void* rows, void* cell, void* cols, void* title, void* width, void* multi, void* selset)
    {
    gTblRows = (tbl_rows_fn)rows;
    gTblCell = (tbl_cell_fn)cell;
    gTblCols = (tbl_cols_fn)cols;
    gTblTitle = (tbl_title_fn)title;
    gTblWidth = (tbl_width_fn)width;
    gTblMulti = (tbl_multi_fn)multi;
    gTblSelSet = (tbl_selset_fn)selset;
    }
#define UX_TBL_ROW_H 32
@interface UXTableHost : NSObject <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic) void* peer;
@property(nonatomic) BOOL outline;
@property(nonatomic, weak) UITableView* table;
@end
@implementation UXTableHost
- (NSInteger)tableView:(UITableView*)tv numberOfRowsInSection:(NSInteger)section
    {
    return gTblRows ? gTblRows(self.peer) : 0;
    }
- (UITableViewCell*)tableView:(UITableView*)tv cellForRowAtIndexPath:(NSIndexPath*)ip
    {
    UITableViewCell* cell = [tv dequeueReusableCellWithIdentifier:@"ux"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"ux"];
    int ncols = gTblCols ? gTblCols(self.peer) : 1;
    if (ncols < 1)
        ncols = 1;
    /* an outline row: indented by its depth, a chevron in front of an item that can open */
    CGFloat x = 16;
    if (self.outline)
        {
        int level = gTblLevel ? gTblLevel(self.peer, (int)ip.row) : 0;
        int disc = gTblDisclosure ? gTblDisclosure(self.peer, (int)ip.row) : 0;
        x += level * UX_TBL_INDENT;
        UIButton* chev = (UIButton*)[cell.contentView viewWithTag:200];
        if (!chev)
            {
            chev = [UIButton buttonWithType:UIButtonTypeSystem];
            chev.tag = 200;
            [chev addTarget:self action:@selector(disclose:) forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:chev];
            }
        chev.frame = CGRectMake(x - 4, 0, UX_TBL_CHEVRON + 4, UX_TBL_ROW_H);
        chev.hidden = (disc & 1) == 0;
        [chev setImage:[UIImage systemImageNamed:(disc & 2) ? @"chevron.down" : @"chevron.right"]
              forState:UIControlStateNormal];
        x += UX_TBL_CHEVRON;
        }
    /* one label per column, kept by tag 100 + column */
    for (int c = 0; c < ncols; c++)
        {
        UILabel* l = (UILabel*)[cell.contentView viewWithTag:100 + c];
        if (!l)
            {
            l = [UILabel new];
            l.tag = 100 + c;
            l.font = [UIFont systemFontOfSize:15];
            [cell.contentView addSubview:l];
            }
        int w = gTblWidth ? gTblWidth(self.peer, c) : 80;
        if (c == ncols - 1)
            w = (int)(tv.bounds.size.width - x - 8);
        l.frame = CGRectMake(x, 0, w > 0 ? w : 40, UX_TBL_ROW_H);
        const char* t = gTblCell ? gTblCell(self.peer, (int)ip.row, c) : "";
        l.text = [NSString stringWithUTF8String:t ? t : ""];
        x += w;
        }
    return cell;
    }
- (void)disclose:(UIButton*)chev
    {
    UITableView* tv = self.table;
    NSIndexPath* ip = [tv indexPathForRowAtPoint:[chev convertPoint:CGPointMake(2, 2) toView:tv]];
    if (ip && gTblToggle)
        gTblToggle(self.peer, (int)ip.row); /* the model re-flattens; the display pass reloads */
    }
- (void)report:(UITableView*)tv
    {
    if (!gTblSelSet || tv.tag)
        return; /* tag != 0: an app push in progress, not the user's */
    NSArray<NSIndexPath*>* sel = tv.indexPathsForSelectedRows;
    int n = (int)sel.count;
    int* rows = calloc(n > 0 ? n : 1, sizeof(int));
    for (int i = 0; i < n; i++)
        rows[i] = (int)sel[i].row;
    gTblSelSet(self.peer, rows, n);
    free(rows);
    }
- (void)tableView:(UITableView*)tv didSelectRowAtIndexPath:(NSIndexPath*)ip
    {
    [self report:tv];
    }
- (void)tableView:(UITableView*)tv didDeselectRowAtIndexPath:(NSIndexPath*)ip
    {
    [self report:tv];
    }
@end
static NSMutableArray* gTblHosts; /* the hosts are the tables' (weak) data sources: keep them */
static UIView* tblHeader(void* peer, CGFloat width)
    {
    int ncols = gTblCols ? gTblCols(peer) : 0;
    BOOL any = NO;
    for (int c = 0; c < ncols; c++)
        if (gTblTitle && gTblTitle(peer, c) && gTblTitle(peer, c)[0])
            any = YES;
    if (!any)
        return nil;
    UIView* h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 28)];
    h.backgroundColor = UIColor.secondarySystemBackgroundColor;
    CGFloat x = 16;
    for (int c = 0; c < ncols; c++)
        {
        int w = gTblWidth ? gTblWidth(peer, c) : 80;
        UILabel* l = [[UILabel alloc] initWithFrame:CGRectMake(x, 0, w, 28)];
        l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        l.textColor = UIColor.secondaryLabelColor;
        l.text = [NSString stringWithUTF8String:gTblTitle(peer, c) ? gTblTitle(peer, c) : ""];
        [h addSubview:l];
        x += w;
        }
    return h;
    }
void ux_ios_make_table(int handle, int node, int x, int y, int w, int h, void* peer, int outline)
    {
    UITableView* tv = [[UITableView alloc] initWithFrame:CGRectMake(x, y, w, h) style:UITableViewStylePlain];
    UXTableHost* host = [UXTableHost new];
    host.peer = peer;
    host.outline = outline != 0;
    host.table = tv;
    if (!gTblHosts)
        gTblHosts = [NSMutableArray new];
    [gTblHosts addObject:host];
    tv.dataSource = host;
    tv.delegate = host;
    tv.rowHeight = UX_TBL_ROW_H;
    tv.allowsMultipleSelection = gTblMulti ? (gTblMulti(peer) != 0) : NO;
    tv.tableHeaderView = tblHeader(peer, w);
    [gWin[handle] addSubview:tv];
    gCtl[handle][node] = tv;
    }
void ux_ios_table_reload(int handle, int node)
    {
    UITableView* tv = (UITableView*)gCtl[handle][node];
    if ([tv isKindOfClass:UITableView.class])
        {
        NSArray* keep = tv.indexPathsForSelectedRows;
        tv.tag = 1;
        [tv reloadData];
        for (NSIndexPath* ip in keep)
            if (ip.row < [tv numberOfRowsInSection:0])
                [tv selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone];
        tv.tag = 0;
        }
    }
/* The app's selection, pushed in (programmatic selection never calls the delegate, and the tag
 * mutes it anyway). */
void ux_ios_table_select(int handle, int node, int* rows, int n)
    {
    UITableView* tv = (UITableView*)gCtl[handle][node];
    if (![tv isKindOfClass:UITableView.class])
        return;
    tv.tag = 1;
    for (NSIndexPath* ip in tv.indexPathsForSelectedRows)
        [tv deselectRowAtIndexPath:ip animated:NO];
    for (int i = 0; i < n; i++)
        if (rows[i] < [tv numberOfRowsInSection:0])
            [tv selectRowAtIndexPath:[NSIndexPath indexPathForRow:rows[i] inSection:0] animated:NO
                      scrollPosition:UITableViewScrollPositionNone];
    tv.tag = 0;
    }
/* Tests: the view's row count, whether a row is selected in it, a cell's text as the cell shows it,
 * and a USER's tap on a row (select, then the delegate, as UIKit does for a tap). */
int ux_ios_test_table_rows(int handle, int node)
    {
    UITableView* tv = (UITableView*)gCtl[handle][node];
    return [tv isKindOfClass:UITableView.class] ? (int)[tv numberOfRowsInSection:0] : -1;
    }
int ux_ios_test_table_selected(int handle, int node, int row)
    {
    UITableView* tv = (UITableView*)gCtl[handle][node];
    for (NSIndexPath* ip in tv.indexPathsForSelectedRows)
        if (ip.row == row)
            return 1;
    return 0;
    }
int ux_ios_test_table_cell_is(int handle, int node, int row, int col, const char* want)
    {
    UITableView* tv = (UITableView*)gCtl[handle][node];
    UITableViewCell* cell = [tv.dataSource tableView:tv cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    UILabel* l = (UILabel*)[cell.contentView viewWithTag:100 + col];
    return l && [l.text isEqualToString:[NSString stringWithUTF8String:want]];
    }
/* Tests: an outline row's chevron as shown (0 none, 1 closed, 2 open) and its indent (the first
 * column's x), and a USER's tap on the chevron (the button's own action, as a touch sends it). */
int ux_ios_test_table_chevron(int handle, int node, int row)
    {
    UITableView* tv = (UITableView*)gCtl[handle][node];
    UITableViewCell* cell = [tv.dataSource tableView:tv cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    UIButton* chev = (UIButton*)[cell.contentView viewWithTag:200];
    if (!chev || chev.hidden)
        return 0;
    UIImage* down = [UIImage systemImageNamed:@"chevron.down"];
    return [[chev imageForState:UIControlStateNormal] isEqual:down] ? 2 : 1;
    }
int ux_ios_test_table_indent(int handle, int node, int row)
    {
    UITableView* tv = (UITableView*)gCtl[handle][node];
    UITableViewCell* cell = [tv.dataSource tableView:tv cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    return (int)[cell.contentView viewWithTag:100].frame.origin.x;
    }
void ux_ios_test_table_disclose(int handle, int node, int row)
    {
    UITableView* tv = (UITableView*)gCtl[handle][node];
    [tv layoutIfNeeded];
    UITableViewCell* cell = [tv cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    [(UIButton*)[cell.contentView viewWithTag:200] sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
int ux_ios_test_table_shown(int handle, int node)
    {
    UITableView* tv = (UITableView*)gCtl[handle][node];
    if (![tv isKindOfClass:UITableView.class])
        return -1;
    /* ask the data source afresh (a cached count would hide a source that has gone away) */
    [tv reloadData];
    [tv layoutIfNeeded];
    return (int)tv.visibleCells.count;
    }
void ux_ios_test_table_tap(int handle, int node, int row)
    {
    UITableView* tv = (UITableView*)gCtl[handle][node];
    NSIndexPath* ip = [NSIndexPath indexPathForRow:row inSection:0];
    if (!tv.allowsMultipleSelection)
        for (NSIndexPath* o in tv.indexPathsForSelectedRows)
            [tv deselectRowAtIndexPath:o animated:NO];
    [tv selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone];
    [tv.delegate tableView:tv didSelectRowAtIndexPath:ip];
    }

// ── native navigation: a real UINavigationController (UXNB v2 §5) ──────────────────────────────
// UXNavigationController hands its pushes and pops here, and the platform does the rest: the bar,
// the Back button (titled with the form underneath), the push animation and the interactive
// edge-swipe.  A pop the USER makes (Back, a completed swipe) is reported back through gNavPopped.
//
// HOW ONE DRAWN WINDOW LIVES IN A STACK OF VIEW CONTROLLERS.  UXKit draws a window's whole tree into
// one container view (gWin), native controls on top.  The navigation controller covers the nav's rect
// of that window; the LIVE container sits in the TOP view controller's view, offset so that it stays
// exactly where it was on screen (the view controller's view starts below the bar and clips, so the
// drawn content's bar strip is hidden under the native bar).  The forms underneath are SNAPSHOTS of
// the container taken as they were covered -- which is what an edge-swipe reveals, and what a pop
// slides back to.  When a pop completes, the live container moves into the revealed view controller
// and its snapshot is dropped once the re-revealed form has redrawn.
@interface UXNavHost : NSObject <UINavigationControllerDelegate>
@property(nonatomic, strong) UINavigationController* nav;
@property(nonatomic) int handle;   // the UXKit window
@property(nonatomic) int navId;    // the neutral controller's id
@property(nonatomic) CGRect rect;  // the nav's rect, in the window
@property(nonatomic) NSInteger known; // the depth the neutral model has
@end
typedef void (*ux_nav_popped_fn)(int);
static ux_nav_popped_fn gNavPopped;
static NSMutableArray<UXNavHost*>* gNavHosts;
#define UX_NAV_SNAP_TAG 0x5A95
void ux_ios_set_nav_popped(void* fn)
    {
    gNavPopped = (ux_nav_popped_fn)fn;
    }
static CGFloat navBarH(UXNavHost* h)
    {
    CGFloat b = h.nav.navigationBar.frame.size.height;
    return b > 0 ? b : 44;
    }
// Put the live window container into `vc`'s view, where it stays put on screen.
static void navPlaceLive(UXNavHost* h, UIViewController* vc)
    {
    UIView* v = gWin[h.handle];
    if (!v || !vc)
        return;
    CGSize ws = v.bounds.size;
    [vc.view addSubview:v];
    v.frame = CGRectMake(-h.rect.origin.x, -(h.rect.origin.y + navBarH(h)), ws.width, ws.height);
    UIView* snap = [vc.view viewWithTag:UX_NAV_SNAP_TAG];
    if (snap)
        [vc.view bringSubviewToFront:snap]; // the snapshot stays on top until the live view has redrawn
    }
static void navDropSnapLater(UIViewController* vc)
    {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      [[vc.view viewWithTag:UX_NAV_SNAP_TAG] removeFromSuperview];
    });
    }
static UIView* navSnapshot(UXNavHost* h)
    {
    UIView* v = gWin[h.handle];
    if (!v || !v.window)
        return nil;
    UIView* s = [v snapshotViewAfterScreenUpdates:NO];
    s.tag = UX_NAV_SNAP_TAG;
    return s;
    }
@implementation UXNavHost
- (void)navigationController:(UINavigationController*)nc
       didShowViewController:(UIViewController*)vc
                    animated:(BOOL)animated
    {
    NSInteger n = (NSInteger)nc.viewControllers.count;
    if (n >= self.known)
        return; // a push, or an interactive swipe the user abandoned: nothing moved
    // The user popped (Back, or a completed swipe).  Bring the live view to the revealed form, tell
    // the model (once per level popped), and let it redraw under the snapshot.
    NSInteger levels = self.known - n;
    self.known = n;
    navPlaceLive(self, vc);
    for (NSInteger i = 0; i < levels; i++)
        if (gNavPopped)
            gNavPopped(self.navId);
    [gDraw[self.handle] setNeedsDisplay];
    navDropSnapLater(vc);
    }
@end

void* ux_ios_nav_attach(int win, int navId, int x, int y, int w, int h)
    {
    if (win <= 0 || win >= UXIOS_MAXW || !gWin[win])
        return NULL;
    if (!gNavHosts)
        gNavHosts = [NSMutableArray new];
    UXNavHost* host = [UXNavHost new];
    host.handle = win;
    host.navId = navId;
    host.rect = CGRectMake(x, y, w, h);
    host.known = 0;
    [gNavHosts addObject:host];
    void* token = (void*)(intptr_t)gNavHosts.count; // 1-based
    // Attach on the next turn: the neutral side asks from inside a draw, and the window container is
    // about to be re-parented -- not something to do to a view in the middle of drawing it.  Every
    // later push and pop is queued the same way, so they stay in order behind this.
    dispatch_async(dispatch_get_main_queue(), ^{
      UINavigationController* nav = [UINavigationController new];
      nav.delegate = host;
      nav.navigationBar.translucent = NO;
      host.nav = nav;
      UIViewController* root = gWindow.rootViewController;
      UIView* v = gWin[win];
      [root addChildViewController:nav];
      CGRect wf = v.frame; // the window, in the safe-area container
      nav.view.frame = CGRectMake(wf.origin.x + x, wf.origin.y + y, w, h);
      [v.superview insertSubview:nav.view aboveSubview:v];
      [nav didMoveToParentViewController:root];
    });
    return token;
    }
static UXNavHost* navHost(void* token)
    {
    NSInteger i = (NSInteger)(intptr_t)token - 1;
    return (gNavHosts && i >= 0 && i < (NSInteger)gNavHosts.count) ? gNavHosts[i] : nil;
    }
void ux_ios_nav_push(void* token, const char* title, int animated)
    {
    UXNavHost* h = navHost(token);
    if (!h)
        return;
    // The covered form, as it looks NOW: the model has switched forms but the window has not
    // redrawn yet (a redraw is only ever scheduled).
    UIView* snap = (animated && h.nav && h.nav.viewControllers.count > 0) ? navSnapshot(h) : nil;
    NSString* t = [NSString stringWithUTF8String:title ? title : ""];
    h.known++;
    dispatch_async(dispatch_get_main_queue(), ^{
      UIViewController* prev = h.nav.topViewController;
      if (prev && snap)
          {
          snap.frame = gWin[h.handle].frame;
          [prev.view addSubview:snap];
          }
      UIViewController* vc = [UIViewController new];
      vc.title = t;
      vc.edgesForExtendedLayout = UIRectEdgeNone;
      vc.view.clipsToBounds = YES;
      vc.view.backgroundColor = UIColor.systemBackgroundColor;
      [h.nav pushViewController:vc animated:animated && prev != nil];
      [h.nav.view layoutIfNeeded];
      navPlaceLive(h, vc);
    });
    }
void ux_ios_nav_pop(void* token, int animated)
    {
    UXNavHost* h = navHost(token);
    if (!h)
        return;
    UIView* snap = animated ? navSnapshot(h) : nil; // the departing form, before the model's redraw
    if (h.known > 1)
        h.known--; // an app pop: the delegate must not report it back
    dispatch_async(dispatch_get_main_queue(), ^{
      NSArray* vcs = h.nav.viewControllers;
      if (vcs.count < 2)
          return;
      UIViewController* top = vcs.lastObject;
      UIViewController* under = vcs[vcs.count - 2];
      if (snap)
          {
          snap.frame = gWin[h.handle].frame;
          [top.view addSubview:snap];
          }
      [[under.view viewWithTag:UX_NAV_SNAP_TAG] removeFromSuperview];
      navPlaceLive(h, under);
      [gDraw[h.handle] setNeedsDisplay];
      [h.nav popViewControllerAnimated:animated];
    });
    }
// The readback (a portrait, a pixel gate) renders the window's own view; a native navigation bar is
// not inside it -- it belongs to the navigation controller beside it -- so it is drawn on top here,
// at the nav's rect.
static void navRenderBars(int handle, CGContextRef ctx)
    {
    // A navigation controller attaches (and takes its pushes) on the next turn of the main loop; a
    // readback straight after building would beat it.  Let the queued work run first (bounded).
    for (int spin = 0; spin < 20; spin++)
        {
        BOOL pending = NO;
        for (UXNavHost* h in gNavHosts)
            if (h.handle == handle && (!h.nav || (NSInteger)h.nav.viewControllers.count < h.known))
                pending = YES;
        if (!pending)
            break;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        }
    for (UXNavHost* h in gNavHosts)
        {
        if (h.handle != handle || !h.nav)
            continue;
        UINavigationBar* bar = h.nav.navigationBar;
        [h.nav.view layoutIfNeeded];
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, h.rect.origin.x, h.rect.origin.y + bar.frame.origin.y);
        [bar.layer renderInContext:ctx];
        CGContextRestoreGState(ctx);
        }
    }
// A window closing takes its navigation controllers with it.
static void navWindowClosed(int handle)
    {
    for (UXNavHost* h in gNavHosts)
        if (h.handle == handle && h.nav)
            {
            [h.nav willMoveToParentViewController:nil];
            [h.nav.view removeFromSuperview];
            [h.nav removeFromParentViewController];
            h.nav = nil;
            }
    }

// Tests: what the stack shows, and the user's Back.
int ux_ios_test_nav_depth(void* token)
    {
    UXNavHost* h = navHost(token);
    return h && h.nav ? (int)h.nav.viewControllers.count : -1;
    }
int ux_ios_test_nav_title_is(void* token, int fromTop, const char* want)
    {
    UXNavHost* h = navHost(token);
    NSArray* vcs = h.nav.viewControllers;
    NSInteger i = (NSInteger)vcs.count - 1 - fromTop;
    if (!h || i < 0)
        return 0;
    return [((UIViewController*)vcs[i]).title isEqualToString:[NSString stringWithUTF8String:want]];
    }
int ux_ios_test_nav_live_on_top(void* token)
    {
    UXNavHost* h = navHost(token);
    return h && h.nav && gWin[h.handle].superview == h.nav.topViewController.view;
    }
int ux_ios_test_nav_swipe_enabled(void* token)
    {
    UXNavHost* h = navHost(token);
    return h && h.nav && h.nav.interactivePopGestureRecognizer != nil;
    }
void ux_ios_test_nav_user_back(void* token)
    {
    UXNavHost* h = navHost(token);
    [h.nav popViewControllerAnimated:YES]; // exactly what the bar's Back button does
    }
// Tests: is a native button with this title on screen (in the window, not hidden, nor any ancestor)?
int ux_ios_test_control_visible(int handle, const char* title)
    {
    NSString* t = [NSString stringWithUTF8String:title];
    for (int n = 0; n < 256; n++)
        {
        UIView* c = gCtl[handle][n];
        if (![c isKindOfClass:UIButton.class] || ![[(UIButton*)c titleForState:UIControlStateNormal] isEqualToString:t])
            continue;
        if (!c.window)
            return 0;
        for (UIView* v = c; v; v = v.superview)
            if (v.hidden || v.alpha == 0)
                return 0;
        return 1;
        }
    return 0;
    }
// Tests: a touch on window `handle`'s drawn content, entering where UIKit's touchesBegan/Moved/Ended
// would (the simulator has no tap injection to come in through UIKit itself).
void ux_ios_test_touch(int handle, int phase, int x, int y)
    {
    if (gTouch && gContentUd[handle])
        gTouch(gContentUd[handle], phase, x, y);
    }
typedef void (*ux_later_fn)(void);
/* A run-loop timer in the common modes, not a main-queue block: the main queue is serial, so a
 * step that runs a modal (a nested run loop: the alert, the document picker) from inside a block
 * would starve every later block -- including the one that answers the modal. */
void ux_ios_test_call_later(void* fn, int ms)
    {
    ux_later_fn f = (ux_later_fn)fn;
    CFRunLoopTimerRef t = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + ms / 1000.0, 0, 0, 0, ^(CFRunLoopTimerRef x) { f(); });
    CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
    CFRelease(t);
    }

// ── the shell (Option B: run()'s iOS inside) ────────────────────────────────
@interface UXIosDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@end
@implementation UXIosDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)opts
    {
    gWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController* vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;
    self.window = gWindow;
    gWindow.rootViewController = vc;
    [gWindow makeKeyAndVisible];
    // Out-of-bounds areas are the PLATFORM's problem, solved by window
    // positioning: every toolkit window attaches to this container, which is
    // pinned to the safe-area guide — so a window at y=0 sits below the
    // notch, and the app never learns the word "inset".
    gSafeRoot = [UIView new];
    gSafeRoot.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:gSafeRoot];
    UILayoutGuide* safe = vc.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [gSafeRoot.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [gSafeRoot.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [gSafeRoot.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [gSafeRoot.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];
    [vc.view layoutIfNeeded]; // resolve bounds before the entry runs
    if (gEntry)
        gEntry(); // the neutral applicationDidStart moment
    return YES;
    }
@end

void ux_ios_shell_run(void)
    {
    char* argv[] = {(char*)"uxkit", NULL};
    @autoreleasepool
        {
        UIApplicationMain(1, argv, nil, @"UXIosDelegate");
        }
    }

// (_putc, the console primitive, comes from the arm64 rt objects that ride in
// every link — the future support/ios layer owns it; the shim never defines it.)
