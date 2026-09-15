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
@implementation UXDrawView
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
void ux_ios_window_close(int handle)
    {
    UIView* v = gWin[handle];
    if (!v)
        return;
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
void ux_ios_test_watchdog(int ms, int rc)
    {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     exit(rc);
                   });
    }

// ── drawing ops (the CGContext of the draw in flight) ───────────────────────
static void setRGB(int r, int g, int b)
    {
    CGContextSetRGBFillColor(gCtx, r / 255.0, g / 255.0, b / 255.0, 1.0);
    }
void ux_ios_fill(int x, int y, int w, int h, int r, int g, int b)
    {
    if (!gCtx)
        return;
    setRGB(r, g, b);
    CGContextFillRect(gCtx, CGRectMake(x, y, w, h));
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
void ux_ios_poly(short* xy, int n, int r, int g, int b)
    {
    if (!gCtx || n < 3)
        return;
    setRGB(r, g, b);
    CGContextBeginPath(gCtx);
    CGContextMoveToPoint(gCtx, xy[0], xy[1]);
    for (int i = 1; i < n; i++)
        CGContextAddLineToPoint(gCtx, xy[i * 2], xy[i * 2 + 1]);
    CGContextClosePath(gCtx);
    CGContextFillPath(gCtx);
    }
static void drawString(const char* s, int x, int y, int r, int g, int b, UIFont* font)
    {
    NSString* t = [NSString stringWithUTF8String:s];
    [t drawAtPoint:CGPointMake(x, y)
        withAttributes:@{NSFontAttributeName : font,
                         NSForegroundColorAttributeName :
                             [UIColor colorWithRed:r / 255.0
                                             green:g / 255.0
                                              blue:b / 255.0
                                             alpha:1]}];
    }
void ux_ios_text(const char* s, int x, int y, int r, int g, int b, int size)
    {
    if (!gCtx)
        return;
    drawString(s, x, y, r, g, b, [UIFont systemFontOfSize:size > 0 ? size : 13]);
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
    drawString(s, x, y, r, g, b, f);
    }
void ux_ios_stroke_path(int* ops, int n, int width, int startCap, int endCap,
                        int r, int g, int b)
    {
    if (!gCtx || n <= 0 || width <= 0)
        return;
    CGContextSetRGBStrokeColor(gCtx, r / 255.0, g / 255.0, b / 255.0, 1.0);
    CGContextSetLineWidth(gCtx, width);
    CGContextSetLineJoin(gCtx, kCGLineJoinRound);
    int cap = startCap > endCap ? startCap : endCap;
    CGContextSetLineCap(gCtx, cap == 1 ? kCGLineCapRound : (cap == 2 ? kCGLineCapSquare : kCGLineCapButt));
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
