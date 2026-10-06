/* libUXGtk.c — the GTK4 shim under UXGtkDriver (sibling of libUXAppKit.m /
 * libUXIos.m): the Linux-desktop backend, GTK4 per the plan (phase 1b).
 *
 * A UX window is a GtkWindow holding a GtkFixed (absolute layout, the
 * toolkit's coordinate model) with a GtkDrawingArea across it as the paint
 * seam — its draw func binds a cairo_t and calls the registered content
 * callback, which walks the neutral tree and comes back through the
 * ux_gtk_* drawing ops.  Native controls (real GtkButton/GtkCheckButton/
 * GtkEntry/GtkScale/GtkSpinButton/GtkProgressBar/GtkDropDown/GtkLabel)
 * overlay it in the fixed, keyed [handle][node]; their signals land in the
 * registered fire/value/field hooks — the notification model every native
 * backend shares.
 *
 * Headless proof rig: ux_gtk_render() runs the content callback against an
 * offscreen cairo image surface (the same drawing chain, no compositor
 * needed); ux_gtk_pixel() reads it back.  ux_gtk_test_click() emits the
 * real "clicked" signal on a native button — GTK4 removed synthetic event
 * injection, and the signal IS the button's genuine fire path.
 */
#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <dlfcn.h>
#include <pthread.h>
#include "ux_posix_fs.h" // listDir / delete / rename / copy for the drawn file panel

#define UXGTK_MAXW 64
/* The nodes of one window's tree a native widget can be made for (a designer's window runs to
 * several hundred). */
#define UXGTK_MAXN 4096

typedef void (*ux_content_fn)(int handle, int wx, int wy, int ww, int wh, void* ud);
typedef void (*ux_fire_fn)(int handle, int node);
typedef void (*ux_value_fn)(int handle, int node, int value);
typedef void (*ux_field_fn)(int handle, int node);
typedef void (*ux_mouse_fn)(int kind, int x, int y, int handle, int extra);

static ux_fire_fn gFire;
static ux_value_fn gValue;
static ux_field_fn gField;
void ux_gtk_set_control_fire(void* fn)
    {
    gFire = (ux_fire_fn)fn;
    }
void ux_gtk_set_value_changed(void* fn)
    {
    gValue = (ux_value_fn)fn;
    }
void ux_gtk_set_field_hooks(void* fn)
    {
    gField = (ux_field_fn)fn;
    }
/* The same field's other announcement: Return.  GtkEntry's "activate" is exactly that key (and
 * nothing else), so this is the signal the neutral onSubmit rides on. */
static ux_field_fn gFieldSubmit;
void ux_gtk_set_field_submit_hooks(void* fn)
    {
    gFieldSubmit = (ux_field_fn)fn;
    }

/* ── pointer input ───────────────────────────────────────────────────────────
 * GTK had NO toolkit-level pointer input at all: native widgets fired their own
 * "clicked" signals, but a press on a drawing area went nowhere and
 * trackDragStep was a stub returning 0.  Everything UXKit draws and drags
 * itself was therefore dead on Linux -- a split divider, a slider thumb, a
 * scroll drag -- and it failed by doing nothing, which reads as "the toolkit
 * has no split views" rather than as a bug.
 *
 * PROPAGATION PHASE: bubble, deliberately, and it has a known consequence.
 * Events reach the target widget first, so a press on something UXKit DREW
 * (a split divider, a slider thumb, a canvas) bubbles up to this controller and
 * is delivered -- but a press on a NATIVE GtkWidget is consumed by that widget
 * and the toolkit never sees it.  Capture phase would see both, at the cost of
 * a press on a native button being delivered twice: once here (the hit-test
 * finds the control and fires its action) and once through the widget's own
 * "clicked" signal.  GTK4 removed synthetic event injection, so that
 * double-fire cannot be tested headlessly -- and an untestable change that
 * might fire every action in every GTK app twice is not one to make blind.
 *
 * What this costs today: an editor putting a transparent overlay over live
 * native controls (Rocks' canvas) intercepts presses on macOS and Windows,
 * where the overlay is a real native view, but not on GTK, where plain views
 * are drawn rather than realized.  Selecting a native control by clicking it
 * therefore does not yet work on the GTK canvas; the background, boxes and
 * everything toolkit-drawn do.  Closing that needs a driver-level "this window
 * is a design surface" seam, not a propagation phase.
 *
 * A LEGACY event controller rather than GtkGestureClick/GtkGestureDrag: the
 * gestures interpret (thresholds, claiming the sequence, denying each other),
 * and what is wanted here is exactly what AppKit and Win32 provide -- the raw
 * press, motion and release.  One controller per window, no interpretation, no
 * two gestures arguing over who owns the drag.
 */
static ux_mouse_fn gMouse;
static double gPtrX, gPtrY;
static int gBtnDown, gPtrMoved;
void ux_gtk_set_mouse(void* fn)
    {
    gMouse = (ux_mouse_fn)fn;
    }

static GtkWindow* gWin[UXGTK_MAXW];
static GtkFixed* gFix[UXGTK_MAXW];
static GtkWidget* gArea[UXGTK_MAXW];
static ux_content_fn gContent[UXGTK_MAXW];
static void* gContentUd[UXGTK_MAXW];
static GtkWidget* gCtl[UXGTK_MAXW][UXGTK_MAXN];
/* Native scroll containers (UXScrollView): a GtkScrolledWindow whose child is a GtkFixed DOCUMENT
 * holding a drawing area the size of the content, which paints the scroll view's document subtree,
 * and any native control inside the scroll view.  docX/docY are the document's place in the window's
 * content (the toolkit's absolute coordinates, unscrolled: the container owns the offset). */
typedef struct
    {
    GtkWidget* doc;  /* the GtkFixed in the GtkScrolledWindow */
    GtkWidget* area; /* its drawing area */
    void* sv;        /* the UXScrollView */
    int docX, docY;
    } GtkScrollRec;
static GtkScrollRec gScroll[UXGTK_MAXW][UXGTK_MAXN];
static unsigned short gInDoc[UXGTK_MAXW][UXGTK_MAXN]; /* a control moved into scroll node n's document: n + 1 */
static int scroll_doc_point(int handle, double wx, double wy, double* x, double* y);
static char* gFieldBuf[UXGTK_MAXW * UXGTK_MAXN];
static int gFieldCap[UXGTK_MAXW * UXGTK_MAXN];
static int gNextH = 1, gLive = 0;
static cairo_t* gCr; /* the cairo of the draw in flight */

/* ── boot / loop ─────────────────────────────────────────────────────────── */
int ux_gtk_boot(int* w, int* h)
    {
    if (!gtk_init_check())
        return 0;
    GdkDisplay* d = gdk_display_get_default();
    /* The toolkit's frames are the truth: the theme's min-height floors
     * (~34px on Adwaita) silently overrule size requests, so a 28px-row UI
     * overflows.  Drop the floors app-wide — the GTK twin of the Android
     * driver's setMinHeight(0); a control still takes its full REQUESTED
     * frame, it just stops exceeding it. */
    GtkCssProvider* prov = gtk_css_provider_new();
    gtk_css_provider_load_from_string(prov,
                                      "button, entry, spinbutton, dropdown, dropdown button { min-height: 0; min-width: 0; }\n"
                                      "button { padding: 1px 8px; }\n"
                                      "entry { padding: 1px 6px; }\n"
                                      "spinbutton entry, spinbutton button { min-height: 0; padding: 0 4px; }\n");
    gtk_style_context_add_provider_for_display(d, GTK_STYLE_PROVIDER(prov),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(prov);
    GListModel* mons = gdk_display_get_monitors(d);
    GdkMonitor* m = g_list_model_get_n_items(mons) ? g_list_model_get_item(mons, 0) : NULL;
    if (m)
        {
        GdkRectangle r;
        gdk_monitor_get_geometry(m, &r);
        *w = r.width;
        *h = r.height;
        g_object_unref(m);
        }
    else
        {
        *w = 1280;
        *h = 800;
        }
    return 1;
    }
/* a real filled disc (the app-drawn radio's ring and dot) */
void ux_gtk_circle(int cx, int cy, int r, int cr, int cg, int cb)
    {
    if (!gCr)
        return;
    cairo_set_source_rgb(gCr, cr / 255.0, cg / 255.0, cb / 255.0);
    cairo_arc(gCr, cx, cy, r, 0, 6.283185307);
    cairo_fill(gCr);
    }

/* subtree clipping for the draw walk (the scroll viewport) */
void ux_gtk_clip(int x, int y, int w, int h)
    {
    if (!gCr)
        return;
    cairo_save(gCr);
    cairo_rectangle(gCr, x, y, w, h);
    cairo_clip(gCr);
    }
void ux_gtk_clip_round(int x, int y, int w, int h, int r)
    {
    if (!gCr)
        return;
    cairo_save(gCr);
    double rr = r * 2 > w ? w / 2.0 : r * 2 > h ? h / 2.0 : r;
    if (w <= 0 || h <= 0)
        {
        cairo_rectangle(gCr, 0, 0, 0, 0);
        cairo_clip(gCr);
        return;
        }
    if (rr <= 0)
        cairo_rectangle(gCr, x, y, w, h);
    else
        {
        cairo_new_sub_path(gCr);
        cairo_arc(gCr, x + w - rr, y + rr, rr, -1.5707963268, 0);
        cairo_arc(gCr, x + w - rr, y + h - rr, rr, 0, 1.5707963268);
        cairo_arc(gCr, x + rr, y + h - rr, rr, 1.5707963268, 3.1415926536);
        cairo_arc(gCr, x + rr, y + rr, rr, 3.1415926536, 4.7123889804);
        cairo_close_path(gCr);
        }
    cairo_clip(gCr);
    }
void ux_gtk_clip_end(void)
    {
    if (gCr)
        cairo_restore(gCr);
    }

void ux_gtk_pump(void)
    {
    while (g_main_context_pending(NULL))
        g_main_context_iteration(NULL, FALSE);
    }
/* The desktop loop's blocking heart: sleep until ONE source dispatches —
 * input, a redraw, a timer.  Signals (button fires) run inline here, so by
 * the time this returns the neutral state has already advanced; the caller
 * just re-checks isRunning.  This is what makes run()'s loop idle at 0%%. */
void ux_gtk_wait_event(void)
    {
    g_main_context_iteration(NULL, TRUE);
    }
static gboolean ux_gtk_turn_timer(gpointer data)
    {
    (void)data;
    return G_SOURCE_REMOVE;
    }
/* The same wait, given a deadline.  With a frame clock the loop must come back
 * even when nothing is pending, so a one-shot timeout source is attached for
 * the deadline and the blocking wait runs as usual: it returns early when real
 * input arrives, and on the deadline when it does not.  A timeout of 0 or less
 * keeps the plain blocking wait above, so a client without a clock is
 * unchanged. */
void ux_gtk_wait_event_ms(int ms)
    {
    GMainContext* ctx = g_main_context_default();
    if (ms <= 0)
        {
        g_main_context_iteration(ctx, TRUE);
        return;
        }
    g_main_context_iteration(ctx, FALSE); // drain whatever is already ready
    if (g_main_context_pending(ctx))
        {
        return;
        }
    GSource* timer = g_timeout_source_new((guint)ms);
    g_source_set_callback(timer, ux_gtk_turn_timer, NULL, NULL);
    g_source_attach(timer, ctx);
    g_source_unref(timer); // the context holds its own reference until it fires
    g_main_context_iteration(ctx, TRUE);
    }

/* ── windows ─────────────────────────────────────────────────────────────── */
/* Surface coordinates to drawing-area ones.  A GdkEvent reports where the
 * pointer is on the SURFACE, and the toolkit's hit-test works in the content
 * view's own space; on a window with a header bar those differ by the header's
 * height, and skipping this puts every click a few tens of pixels too high. */
static void gtk_to_area(int handle, double* x, double* y)
    {
    if (!gWin[handle] || !gArea[handle])
        return;
    graphene_point_t sp = GRAPHENE_POINT_INIT((float)*x, (float)*y), lp;
    if (gtk_widget_compute_point(GTK_WIDGET(gWin[handle]), gArea[handle], &sp, &lp))
        {
        *x = lp.x;
        *y = lp.y;
        }
    }

/* What a pointer event MEANS to the toolkit, decided once for real events and for a test's injected
 * ones alike.  what: 1 press, 2 release, 3 motion, 4 scroll (px = the DOM's deltaY, positive down). */
void ux_gtk_input(int handle, int what, int button, double x, double y, int px)
    {
    if (what == 4)
        {
        if (px != 0 && gMouse)
            gMouse(11, (int)x, (int)y, handle, px); /* 11 == UXEventWheel */
        return;
        }
    if (what == 1)
        {
        /* The secondary button is the context menu, never a press that starts a drag. */
        if (button == 3)
            {
            if (gMouse)
                gMouse(16, (int)x, (int)y, handle, 0); /* 16 == UXEventRightMouseDown */
            return;
            }
        gPtrX = x;
        gPtrY = y;
        gBtnDown = 1;
        gPtrMoved = 0;
        if (gMouse)
            gMouse(1, (int)x, (int)y, handle, 0); /* 1 == UXEventMouseDown */
        return;
        }
    if (what == 3)
        {
        if ((int)x != (int)gPtrX || (int)y != (int)gPtrY)
            {
            gPtrX = x;
            gPtrY = y;
            gPtrMoved = 1;
            /* With no button down a move is a HOVER, delivered to the view under the pointer; with
             * one down it belongs to the drag (ux_gtk_drag_next). */
            if (!gBtnDown && gMouse)
                gMouse(15, (int)x, (int)y, handle, 0); /* 15 == UXEventMouseMoved */
            }
        return;
        }
    if (button != 3)
        gBtnDown = 0; /* the primary came up */
    }

static gboolean event_cb(GtkEventControllerLegacy* c, GdkEvent* ev, gpointer ud)
    {
    int handle = GPOINTER_TO_INT(ud);
    GdkEventType t = gdk_event_get_event_type(ev);
    double x = 0, y = 0;
    if (t != GDK_BUTTON_PRESS && t != GDK_MOTION_NOTIFY && t != GDK_BUTTON_RELEASE && t != GDK_SCROLL)
        return FALSE;
    gdk_event_get_position(ev, &x, &y);
    double wx = x, wy = y;
    gtk_to_area(handle, &x, &y);
    if (t == GDK_BUTTON_PRESS || t == GDK_BUTTON_RELEASE || t == GDK_MOTION_NOTIFY)
        {
        /* over a native scroll container: its scrollbar and native controls handle their own */
        int on = scroll_doc_point(handle, wx, wy, &x, &y);
        if (on < 0 && t == GDK_BUTTON_PRESS)
            return FALSE; /* the container's scrollbar or a native control: theirs alone */
        }
    if (y < 0 && t != GDK_MOTION_NOTIFY)
        return FALSE; /* on the menu bar above the content: the bar's, not the toolkit's */
    if (t == GDK_SCROLL)
        {
        /* A wheel reports whole clicks (100 px each, as WebKit counts a line), a touchpad its own
         * surface pixels; GTK's sense is the DOM's, positive down. */
        double dx = 0, dy = 0;
        GdkScrollDirection d = gdk_scroll_event_get_direction(ev);
        if (d == GDK_SCROLL_UP)
            dy = -1;
        else if (d == GDK_SCROLL_DOWN)
            dy = 1;
        else if (d == GDK_SCROLL_SMOOTH)
            gdk_scroll_event_get_deltas(ev, &dx, &dy);
        int px = gdk_scroll_event_get_unit(ev) == GDK_SCROLL_UNIT_SURFACE ? (int)dy : (int)(dy * 100.0);
        ux_gtk_input(handle, 4, 0, x, y, px);
        return FALSE;
        }
    int button = (t == GDK_MOTION_NOTIFY) ? 0 : (int)gdk_button_event_get_button(ev);
    ux_gtk_input(handle, t == GDK_BUTTON_PRESS ? 1 : t == GDK_MOTION_NOTIFY ? 3 : 2, button, x, y, 0);
    return FALSE; /* native widgets still get theirs */
    }

/* One modal step of a toolkit-drawn drag: block until the pointer moves or the
 * button comes up.  BLOCKING, not polling -- a spin loop here would burn a core
 * for as long as the user holds the mouse down.  The release is itself an
 * event, so the wait always ends. */
int ux_gtk_drag_next(int* x, int* y)
    {
    if (!gBtnDown)
        return 0;
    /* Wait for a move that has not been reported yet -- then CONSUME the flag,
     * rather than clearing it before the wait.  Clearing first throws away any
     * motion that arrived while the caller was busy redrawing, so a drag falls
     * progressively further behind a fast pointer, and a caller that posts a
     * move and then steps blocks forever waiting for a second one. */
    while (gBtnDown && !gPtrMoved)
        g_main_context_iteration(NULL, TRUE);
    gPtrMoved = 0;
    if (!gBtnDown)
        return 0;
    if (x)
        *x = (int)gPtrX;
    if (y)
        *y = (int)gPtrY;
    return 1;
    }

/* Test seam: a headless gate has no pointer, so it drives these directly and
 * asserts the toolkit reacted.  Same entry points the real events use. */
void ux_gtk_post_press(int handle, int x, int y)
    {
    gPtrX = x;
    gPtrY = y;
    gBtnDown = 1;
    gPtrMoved = 0;
    if (gMouse)
        gMouse(1, x, y, handle, 0);
    }
void ux_gtk_post_motion(int x, int y)
    {
    gPtrX = x;
    gPtrY = y;
    gPtrMoved = 1;
    }
void ux_gtk_post_release(void)
    {
    gBtnDown = 0;
    }

/* ── the input shield (UXKindShield) ─────────────────────────────────────────
 * A bare GtkWidget covering a region, placed LAST in the GtkFixed so it is what
 * the pointer lands on, above the native controls.
 *
 * It deliberately installs no controller of its own.  The window's legacy
 * controller is in the bubble phase, so an event that reaches an unhandled
 * widget travels up to it and is dispatched with the right coordinates -- the
 * shield only has to exist, be targetable, and be on top.  Adding a gesture
 * here would claim the sequence and stop that bubble.
 *
 * A drawing area with no draw function paints nothing, so the controls beneath
 * still show: as on every backend, what is intercepted is the INPUT, not the
 * rendering. */
static GtkWidget* gShieldW[UXGTK_MAXW];
void ux_gtk_make_shield(int handle, int x, int y, int w, int h, int hidden)
    {
    if (!gFix[handle])
        return;
    if (!gShieldW[handle])
        {
        gShieldW[handle] = gtk_drawing_area_new();
        gtk_fixed_put(gFix[handle], gShieldW[handle], x, y);
        }
    else
        {
        gtk_fixed_move(gFix[handle], gShieldW[handle], x, y);
        }
    gtk_widget_set_size_request(gShieldW[handle], w, h);
    gtk_widget_set_visible(gShieldW[handle], hidden ? FALSE : TRUE);
    }
/* Controls realized after the shield are inserted after it and would take the
 * clicks back, so it is re-raised at the end of every realize pass. */
void ux_gtk_raise_shield(int handle)
    {
    GtkWidget* s = gShieldW[handle];
    if (!s || !gFix[handle])
        return;
    GtkWidget* last = gtk_widget_get_last_child(GTK_WIDGET(gFix[handle]));
    if (last && last != s)
        gtk_widget_insert_after(s, GTK_WIDGET(gFix[handle]), last);
    }
/* The switch's ACTUAL state, read back off the widget.  A gate that only checks
 * the toolkit's own field cannot tell "we set the flag" from "the control
 * changed" -- which is precisely the bug this exists to catch: GTK's realize
 * pass pushed frame, hidden and enabled but not the toggle, so a check box
 * changed after its first realize stayed visually stale.  -1 = no such control. */
/* Text alignment on a label or entry: 0 left, 1 centre, 2 right (UX_ALIGN_*).
 * A column of "Name:" / "Size:" labels only lines its colons up when the text is
 * right aligned in boxes whose right edges agree. */
void ux_gtk_set_align(int handle, int node, int a)
    {
    GtkWidget* c = (handle >= 0 && handle < UXGTK_MAXW && node >= 0 && node < UXGTK_MAXN)
                       ? gCtl[handle][node]
                       : NULL;
    if (!c)
        return;
    /* UX_ALIGN_*: 0 left, 1 right, 2 centre -- GEM's te_just numbering. */
    float x = a == 1 ? 1.0f : a == 2 ? 0.5f
                                     : 0.0f;
    if (GTK_IS_LABEL(c))
        gtk_label_set_xalign(GTK_LABEL(c), x);
    else if (GTK_IS_ENTRY(c))
        gtk_entry_set_alignment(GTK_ENTRY(c), x);
    }
/* Read it back, so a gate can tell "we set it" from "the text moved". */
int ux_gtk_get_align(int handle, int node)
    {
    GtkWidget* c = (handle >= 0 && handle < UXGTK_MAXW && node >= 0 && node < UXGTK_MAXN)
                       ? gCtl[handle][node]
                       : NULL;
    if (!c)
        return -1;
    float x = GTK_IS_LABEL(c)   ? gtk_label_get_xalign(GTK_LABEL(c))
              : GTK_IS_ENTRY(c) ? gtk_entry_get_alignment(GTK_ENTRY(c))
                                : -1.0f;
    if (x < 0.0f)
        return -1;
    return x > 0.75f ? 1 : x > 0.25f ? 2
                                     : 0;
    }
int ux_gtk_get_check(int handle, int node)
    {
    GtkWidget* c = (handle >= 0 && handle < UXGTK_MAXW && node >= 0 && node < UXGTK_MAXN)
                       ? gCtl[handle][node]
                       : NULL;
    if (!c || !GTK_IS_CHECK_BUTTON(c))
        return -1;
    return gtk_check_button_get_active(GTK_CHECK_BUTTON(c)) ? 1 : 0;
    }
int ux_gtk_has_shield(int handle)
    {
    return gShieldW[handle] != NULL;
    }
/* Is the shield the last child, i.e. the one the pointer reaches first?  A gate
 * can assert this; GTK4 removed synthetic event injection, so the press itself
 * cannot be posted through the real hit-test the way AppKit's can. */
int ux_gtk_shield_on_top(int handle)
    {
    if (!gShieldW[handle] || !gFix[handle])
        return 0;
    return gtk_widget_get_last_child(GTK_WIDGET(gFix[handle])) == gShieldW[handle];
    }

/* ── GL surface (UXKindGLView) ───────────────────────────────────────────────
 * A real GtkGLArea, placed BELOW the cairo drawing area: the map is the bottom
 * of the stack and a 2D view painted over it lands over it, which is the
 * client's two layers.  The SURFACE is made here, with the tree; the CONTEXT is
 * made only when the app asks, so a view that never asks costs nothing.
 *
 * GTK's GL model is its own and the difference is worth a line: drawing has to
 * happen with the area's FRAMEBUFFER bound, which gtk_gl_area_make_current
 * does, and the toolkit otherwise wants it done inside the "render" signal.
 * The seam's promise is that the context is current for the APP's turn, so
 * make_current is called when the context is made and again after each swap,
 * and the render signal returns TRUE without clearing -- so GTK presents the
 * app's frame instead of wiping it first.
 *
 * The entry points are resolved at run time (dlsym, with libGL/libEGL as the
 * fallback), never linked: the renderer reaches them through ux_gtk_gl_proc and
 * this shim needs only glViewport for itself.
 */
static GtkWidget* gGlA[UXGTK_MAXW][UXGTK_MAXN];
static void* gl_entry(const char* name);

/* THE CLAMP.  The area's framebuffer is GTK's, sized at the allocation times the scale factor, and
 * GTK offers no way to cap it -- but a maximised window at 150-200% scaling on an old integrated GPU,
 * or one across two monitors, can be larger than the GPU's limit.  So when the area is over the limit
 * the renderer gets OUR framebuffer instead, at the clamped size (one factor on both sides, keeping
 * the aspect), bound by make_current with the viewport set to it; and in the render signal, where GTK
 * has bound its own framebuffer, the frame is blitted across, stretched with linear filtering.  Under
 * the limit nothing changes.  ux_gtk_gl_test_max lowers the limit for a gate. */
typedef struct { unsigned fbo, rb; int w, h; unsigned areaFbo; int cornerRGB; } GlClamp;
static GlClamp gClamp[UXGTK_MAXW][UXGTK_MAXN];
static int gGlTestMax = 0;
void ux_gtk_gl_test_max(int px)
    {
    gGlTestMax = px;
    }
typedef void (*gl_genfn)(int, unsigned*);
typedef void (*gl_bindfn)(unsigned, unsigned);
typedef void (*gl_getintfn)(unsigned, int*);
static int gl_max_px(void)
    {
    gl_getintfn gi = (gl_getintfn)gl_entry("glGetIntegerv");
    int m = 0;
    if (gi)
        {
        int v[2] = {0, 0};
        gi(0x0D33, v); /* GL_MAX_TEXTURE_SIZE */
        m = v[0];
        v[0] = 0;
        gi(0x84E8, v); /* GL_MAX_RENDERBUFFER_SIZE */
        if (v[0] > 0 && (m <= 0 || v[0] < m))
            m = v[0];
        v[0] = v[1] = 0;
        gi(0x0D3A, v); /* GL_MAX_VIEWPORT_DIMS */
        if (v[0] > 0 && (m <= 0 || v[0] < m))
            m = v[0];
        if (v[1] > 0 && (m <= 0 || v[1] < m))
            m = v[1];
        }
    if (gGlTestMax > 0 && (m <= 0 || gGlTestMax < m))
        m = gGlTestMax;
    return m;
    }
static void gl_clamp_free(GlClamp* c)
    {
    gl_genfn delFb = (gl_genfn)gl_entry("glDeleteFramebuffers");
    gl_genfn delRb = (gl_genfn)gl_entry("glDeleteRenderbuffers");
    if (c->fbo && delFb)
        delFb(1, &c->fbo);
    if (c->rb && delRb)
        delRb(1, &c->rb);
    c->fbo = c->rb = 0;
    c->w = c->h = 0;
    }
/* With the context current: make sure the renderer's framebuffer is the right one for the area's
 * size now, and bind it.  The renderer always draws into OURS, at the area's size or clamped under the
 * GPU's limit, and the render signal blits it across: GTK's own framebuffer is a texture it swaps
 * between frames, so a frame drawn straight into it was lost the next time the window repainted
 * without the app drawing again (a 2-D view's redraw, a snapshot).  Ours keeps the last frame for every
 * repaint.  Returns 1 when ours is bound; 0 (GTK's own) only without framebuffer objects. */
static int gl_clamp_bind(int handle, int node, int pw, int ph)
    {
    GlClamp* c = &gClamp[handle][node];
    gl_bindfn bindFb = (gl_bindfn)gl_entry("glBindFramebuffer");
    int m = gl_max_px();
    if (!bindFb || pw <= 0 || ph <= 0)
        {
        if (c->fbo)
            {
            gl_clamp_free(c);
            bindFb(0x8D40, c->areaFbo); /* back to GTK's own, as when the area was never clamped */
            typedef void (*vpfn)(int, int, int, int);
            vpfn vp = (vpfn)gl_entry("glViewport");
            if (vp)
                vp(0, 0, pw, ph); /* the viewport follows the drawable */
            }
        return 0;
        }
    double k = (m > 0 && (pw > m || ph > m)) ? (double)m / (pw > ph ? pw : ph) : 1.0;
    int cw = (int)(pw * k), ch = (int)(ph * k);
    if (cw < 1)
        cw = 1;
    if (ch < 1)
        ch = 1;
    if (!c->fbo || c->w != cw || c->h != ch)
        {
        gl_clamp_free(c);
        gl_genfn genFb = (gl_genfn)gl_entry("glGenFramebuffers");
        gl_genfn genRb = (gl_genfn)gl_entry("glGenRenderbuffers");
        gl_bindfn bindRb = (gl_bindfn)gl_entry("glBindRenderbuffer");
        typedef void (*storefn)(unsigned, unsigned, int, int);
        typedef void (*attachfn)(unsigned, unsigned, unsigned, unsigned);
        storefn store = (storefn)gl_entry("glRenderbufferStorage");
        attachfn attach = (attachfn)gl_entry("glFramebufferRenderbuffer");
        if (!genFb || !genRb || !bindRb || !store || !attach)
            {
            bindFb(0x8D40, c->areaFbo);
            return 0;
            }
        genRb(1, &c->rb);
        bindRb(0x8D41, c->rb);             /* GL_RENDERBUFFER */
        store(0x8D41, 0x8058, cw, ch);     /* GL_RGBA8 */
        genFb(1, &c->fbo);
        bindFb(0x8D40, c->fbo);
        attach(0x8D40, 0x8CE0, 0x8D41, c->rb); /* COLOR_ATTACHMENT0 */
        c->w = cw;
        c->h = ch;
        typedef void (*vpfn)(int, int, int, int);
        vpfn vp = (vpfn)gl_entry("glViewport");
        if (vp)
            vp(0, 0, cw, ch); /* the viewport follows the drawable */
        }
    bindFb(0x8D40, c->fbo);
    return 1;
    }

static gboolean gl_render_cb(GtkGLArea* a, GdkGLContext* ctx, gpointer ud)
    {
    (void)ctx;
    int key = GPOINTER_TO_INT(ud);
    int handle = key >> 8, node = key & 255;
    GlClamp* c = (handle >= 0 && handle < UXGTK_MAXW) ? &gClamp[handle][node] : NULL;
    gl_getintfn gi = (gl_getintfn)gl_entry("glGetIntegerv");
    int bound = 0;
    if (gi)
        gi(0x8CA6, &bound); /* GL_DRAW_FRAMEBUFFER_BINDING: GTK's own, bound for this signal */
    if (c)
        c->areaFbo = (unsigned)bound;
    if (c && c->fbo)
        {
        /* The app's frame is in our framebuffer: copy it over the area's (stretched, if clamped). */
        gl_bindfn bindFb = (gl_bindfn)gl_entry("glBindFramebuffer");
        typedef void (*blitfn)(int, int, int, int, int, int, int, int, unsigned, unsigned);
        blitfn blit = (blitfn)gl_entry("glBlitFramebuffer");
        int s = gtk_widget_get_scale_factor(GTK_WIDGET(a));
        int aw = gtk_widget_get_width(GTK_WIDGET(a)) * (s < 1 ? 1 : s);
        int ah = gtk_widget_get_height(GTK_WIDGET(a)) * (s < 1 ? 1 : s);
        if (bindFb && blit)
            {
            bindFb(0x8CA8, c->fbo);            /* READ */
            bindFb(0x8CA9, (unsigned)bound);   /* DRAW */
            blit(0, 0, c->w, c->h, 0, 0, aw, ah, 0x4000, 0x2601); /* COLOR, LINEAR */
            bindFb(0x8D40, (unsigned)bound);
            typedef void (*rpfn)(int, int, int, int, unsigned, unsigned, void*);
            rpfn rp = (rpfn)gl_entry("glReadPixels");
            unsigned char px[4] = {0, 0, 0, 0};
            if (rp)
                rp(aw - 2, ah - 2, 1, 1, 0x1908, 0x1401, px); /* the far corner, for a gate */
            c->cornerRGB = (px[0] << 16) | (px[1] << 8) | px[2];
            }
        }
    return TRUE; /* the app's frame is already in the FBO: no default clear */
    }
static void gl_pixel_size(int handle, int node, int* pw, int* ph);
int ux_gtk_gl_make_current(int handle, int node);
/* The drawable the renderer draws into, in pixels: our framebuffer's size (clamped under the GPU's
 * limit), or the area's when it has none yet.  1 when the area exists. */
int ux_gtk_gl_drawable(int handle, int node, int* pw, int* ph)
    {
    if (handle < 0 || handle >= UXGTK_MAXW || node < 0 || node >= UXGTK_MAXN || !gGlA[handle][node])
        return 0;
    GlClamp* c = &gClamp[handle][node];
    if (c->fbo)
        {
        *pw = c->w;
        *ph = c->h;
        }
    else
        gl_pixel_size(handle, node, pw, ph);
    return *pw > 0 && *ph > 0 ? 1 : 0;
    }
/* The last frame, read out of our framebuffer (which keeps it), top row first, as 0xAARRGGBB. */
int ux_gtk_gl_read(int handle, int node, unsigned* out, int pw, int ph)
    {
    if (!ux_gtk_gl_make_current(handle, node))
        return 0;
    GlClamp* c = &gClamp[handle][node];
    if (!c->fbo || c->w != pw || c->h != ph)
        return 0;
    gl_bindfn bindFb = (gl_bindfn)gl_entry("glBindFramebuffer");
    typedef void (*rpfn)(int, int, int, int, unsigned, unsigned, void*);
    rpfn rp = (rpfn)gl_entry("glReadPixels");
    if (!bindFb || !rp)
        return 0;
    unsigned char* buf = (unsigned char*)malloc((size_t)pw * ph * 4);
    if (!buf)
        return 0;
    bindFb(0x8CA8, c->fbo);                       /* READ */
    rp(0, 0, pw, ph, 0x1908, 0x1401, buf);        /* RGBA, UNSIGNED_BYTE, bottom row first */
    bindFb(0x8D40, c->fbo);
    for (int y = 0; y < ph; y++)
        {
        const unsigned char* r = buf + (size_t)(ph - 1 - y) * pw * 4;
        for (int x = 0; x < pw; x++)
            out[(size_t)y * pw + x] = ((unsigned)r[x * 4 + 3] << 24) | ((unsigned)r[x * 4] << 16) |
                                       ((unsigned)r[x * 4 + 1] << 8) | r[x * 4 + 2];
        }
    free(buf);
    return 1;
    }
/* Test only: the far corner of the area's framebuffer after the last clamped blit (0xRRGGBB). */
int ux_gtk_gl_test_corner(int handle, int node)
    {
    return (handle >= 0 && handle < UXGTK_MAXW && node >= 0 && node < UXGTK_MAXN) ? gClamp[handle][node].cornerRGB : -1;
    }

void ux_gtk_make_gl(int handle, int node, int x, int y, int w, int h, int hidden)
    {
    if (!gFix[handle] || node < 0 || node >= UXGTK_MAXN)
        return;
    if (!gGlA[handle][node])
        {
        GtkWidget* gl = gtk_gl_area_new();
        /* Desktop GL, 3.2 or later: what glKind promises (UX_GL_GL33).  Left to choose, GTK takes
         * OpenGL ES where it prefers it (Mesa under Xvfb did), and a renderer told GL 3.3 then
         * compiles "#version 150" against a GLES context and fails. */
        gtk_gl_area_set_allowed_apis(GTK_GL_AREA(gl), GDK_GL_API_GL);
        gtk_gl_area_set_required_version(GTK_GL_AREA(gl), 3, 2);
        g_signal_connect(gl, "render", G_CALLBACK(gl_render_cb), GINT_TO_POINTER((handle << 8) | node));
        /* BELOW the cairo drawing area, so the toolkit's 2D lands over the map. */
        gtk_widget_insert_before(gl, GTK_WIDGET(gFix[handle]), gArea[handle]);
        gtk_fixed_move(gFix[handle], gl, x, y);
        gGlA[handle][node] = gl;
        }
    else
        {
        gtk_fixed_move(gFix[handle], gGlA[handle][node], x, y);
        }
    gtk_widget_set_size_request(gGlA[handle][node], w, h);
    gtk_widget_set_visible(gGlA[handle][node], hidden ? FALSE : TRUE);
    }

/* The drawable's pixel size: the widget's allocation times its scale factor.
 * The toolkit reports both, so the driver never guesses -- the GTK twin of
 * AppKit's bounds times backingScaleFactor. */
static void gl_pixel_size(int handle, int node, int* pw, int* ph)
    {
    int w = gtk_widget_get_width(gGlA[handle][node]);
    int h = gtk_widget_get_height(gGlA[handle][node]);
    int s = gtk_widget_get_scale_factor(gGlA[handle][node]);
    if (s < 1)
        s = 1;
    *pw = w * s;
    *ph = h * s;
    }

/* The context is the area's and outlives the token the driver hands the app, so
 * "release" only forgets the widget; GTK frees it with the window. */
/* Before a context is handed out: let GTK lay the GL area out, so its drawable has its size from the
 * first call -- as on the other backends, where the size is known when the context is.  GTK sizes a
 * widget only when its main loop turns, and an app that sets up (or draws headless frames) before
 * the run loop has turned would otherwise see 0x0 and draw into nothing.  Bounded: about a second. */
static gboolean ux_gtk_gl_beat(gpointer ud) { (void)ud; return G_SOURCE_CONTINUE; }
static void gl_wait_allocated(int handle, int node)
    {
    GtkWidget* a = gGlA[handle][node];
    if (!a || !gtk_widget_get_visible(a))
        return;
    if (gtk_widget_get_width(a) > 0 && gtk_widget_get_realized(a))
        return;
    guint beat = g_timeout_add(5, ux_gtk_gl_beat, NULL);
    for (int spins = 0; spins < 200 && (gtk_widget_get_width(a) <= 0 || !gtk_widget_get_realized(a)); spins++)
        g_main_context_iteration(NULL, TRUE);
    g_source_remove(beat);
    }
int ux_gtk_gl_make_current(int handle, int node)
    {
    if (handle >= 0 && handle < UXGTK_MAXW && node >= 0 && node < UXGTK_MAXN)
        gl_wait_allocated(handle, node);
    if (handle < 0 || handle >= UXGTK_MAXW || node < 0 || node >= UXGTK_MAXN || !gGlA[handle][node])
        return 0;
    if (!gtk_widget_get_realized(gGlA[handle][node]))
        return 0;
    gtk_gl_area_make_current(GTK_GL_AREA(gGlA[handle][node]));
    if (gtk_gl_area_get_error(GTK_GL_AREA(gGlA[handle][node])))
        return 0;
    int pw, ph;
    gl_pixel_size(handle, node, &pw, &ph);
    gl_clamp_bind(handle, node, pw, ph); /* the renderer draws into ours, clamped over the GPU's limit */
    return 1;
    }

/* ---- sound (UXSound.play) --------------------------------------------------------------------
 * GTK has no audio, so this is PulseAudio's simple API (PipeWire serves the same protocol), loaded at
 * run time so the shim needs neither its headers nor the library to link.  Connecting is done here,
 * synchronously, so with no sound server play() answers 0 honestly; the write and the drain run on a
 * C thread per sound -- no toolkit code on it -- so sounds overlap and the caller never blocks. */
typedef struct { int format; unsigned rate; unsigned char channels; } UXPaSpec;
typedef void* (*pa_new_fn)(const char*, const char*, int, const char*, const char*, const UXPaSpec*,
                            const void*, const void*, int*);
typedef int (*pa_io_fn)(void*, const void*, size_t, int*);
typedef int (*pa_drain_fn)(void*, int*);
typedef void (*pa_free_fn)(void*);
static pa_new_fn g_paNew;
static pa_io_fn g_paWrite;
static pa_drain_fn g_paDrain;
static pa_free_fn g_paFree;
static int g_paTried;
static volatile int g_paLive; /* sounds still playing, for a gate */
typedef struct { void* s; short* pcm; int frames; } UXPaJob;
static void* pa_play_thread(void* arg)
    {
    UXPaJob* j = (UXPaJob*)arg;
    int err = 0;
    g_paWrite(j->s, j->pcm, (size_t)j->frames * 2, &err);
    g_paDrain(j->s, &err);
    g_paFree(j->s);
    free(j->pcm);
    free(j);
    __sync_fetch_and_sub(&g_paLive, 1);
    return NULL;
    }
int ux_gtk_audio_play(const short* pcm, int frames, int rate)
    {
    if (!pcm || frames <= 0 || rate <= 0)
        return 0;
    if (!g_paTried)
        {
        g_paTried = 1;
        void* lib = dlopen("libpulse-simple.so.0", RTLD_LAZY);
        if (lib)
            {
            g_paNew = (pa_new_fn)dlsym(lib, "pa_simple_new");
            g_paWrite = (pa_io_fn)dlsym(lib, "pa_simple_write");
            g_paDrain = (pa_drain_fn)dlsym(lib, "pa_simple_drain");
            g_paFree = (pa_free_fn)dlsym(lib, "pa_simple_free");
            }
        }
    if (!g_paNew || !g_paWrite || !g_paDrain || !g_paFree)
        return 0;
    UXPaSpec spec = {3 /* PA_SAMPLE_S16LE */, (unsigned)rate, 1};
    int err = 0;
    void* s = g_paNew(NULL, "UXKit", 1 /* PA_STREAM_PLAYBACK */, NULL, "sound", &spec, NULL, NULL, &err);
    if (!s)
        return 0; /* no sound server */
    UXPaJob* j = (UXPaJob*)malloc(sizeof *j);
    j->s = s;
    j->frames = frames;
    j->pcm = (short*)malloc((size_t)frames * 2);
    memcpy(j->pcm, pcm, (size_t)frames * 2);
    __sync_fetch_and_add(&g_paLive, 1);
    pthread_t t;
    if (pthread_create(&t, NULL, pa_play_thread, j) != 0)
        {
        __sync_fetch_and_sub(&g_paLive, 1);
        g_paFree(s);
        free(j->pcm);
        free(j);
        return 0;
        }
    pthread_detach(t);
    return 1;
    }
int ux_gtk_audio_playing(void)
    {
    return g_paLive;
    }

/* A GL entry point by name.  dlsym on the process first (the workspace on
 * macOS, the framework's symbols already loaded); libGL/libEGL opened lazily as
 * the fallback, because on Linux the toolkit loads GL private to itself. */
static void* gl_entry(const char* name)
    {
    void* p = dlsym(RTLD_DEFAULT, name);
    if (p)
        return p;
    static void* lib;
    if (!lib)
        {
        lib = dlopen("libGL.so.1", RTLD_LAZY | RTLD_GLOBAL);
        if (!lib)
            lib = dlopen("libGL.so", RTLD_LAZY | RTLD_GLOBAL);
        if (!lib)
            lib = dlopen("libEGL.so.1", RTLD_LAZY | RTLD_GLOBAL);
        }
    if (lib)
        return dlsym(lib, name);
    return NULL;
    }

/* The viewport is the driver's: the drawable's size in PIXELS, set from the
 * allocation and not from anything the app could guess at. */
void ux_gtk_gl_viewport(int handle, int node)
    {
    if (!ux_gtk_gl_make_current(handle, node))
        return;
    typedef void (*vpfn)(int, int, int, int);
    vpfn vp = (vpfn)gl_entry("glViewport");
    if (!vp)
        return;
    int pw, ph;
    gl_pixel_size(handle, node, &pw, &ph);
    GlClamp* c = &gClamp[handle][node];
    if (c->fbo)
        {
        pw = c->w; /* the drawable is ours (smaller than the area when clamped) */
        ph = c->h;
        }
    if (pw < 1)
        pw = 1;
    if (ph < 1)
        ph = 1;
    vp(0, 0, pw, ph);
    }

/* The swap is the toolkit's: the frame is in the area's FBO and queue_render
 * makes GTK present it.  The context is made current again afterwards so the
 * NEXT app turn has it, which is the promise the seam makes. */
void ux_gtk_gl_present(int handle, int node)
    {
    if (handle < 0 || handle >= UXGTK_MAXW || node < 0 || node >= UXGTK_MAXN || !gGlA[handle][node])
        return;
    gtk_gl_area_queue_render(GTK_GL_AREA(gGlA[handle][node]));
    ux_gtk_gl_make_current(handle, node);
    }

/* 1 when the area reports a context error (no GL, or a failed context), 0 when
 * it is healthy, -1 when there is no surface.  A renderer that never asks does
 * not care, but the gate does. */
int ux_gtk_gl_error(int handle, int node)
    {
    if (handle < 0 || handle >= UXGTK_MAXW || node < 0 || node >= UXGTK_MAXN || !gGlA[handle][node])
        return -1;
    return gtk_gl_area_get_error(GTK_GL_AREA(gGlA[handle][node])) ? 1 : 0;
    }

void* ux_gtk_gl_proc(const char* name)
    {
    if (!name)
        return NULL;
    return gl_entry(name);
    }

void ux_gtk_gl_forget(int handle)
    {
    if (handle < 0 || handle >= UXGTK_MAXW)
        return;
    for (int n = 0; n < UXGTK_MAXN; n++)
        {
        gGlA[handle][n] = NULL;
        gClamp[handle][n].fbo = gClamp[handle][n].rb = 0; /* freed with the window's context */
        gClamp[handle][n].w = gClamp[handle][n].h = 0;
        }
    }

static void draw_cb(GtkDrawingArea* a, cairo_t* cr, int w, int h, gpointer ud)
    {
    int handle = GPOINTER_TO_INT(ud);
    if (!gContent[handle])
        return;
    gCr = cr;
    gContent[handle](handle, 0, 0, w, h, gContentUd[handle]);
    gCr = NULL;
    }
/* ── the menu bar ────────────────────────────────────────────────────────── */
/* A real GtkPopoverMenuBar over a GMenu, one bar per window, all sharing one model and one action
 * group ("ux").  Item (t, j) is the action "ux.m<t>_<j>"; a separator starts a new section, which is
 * how a GMenu draws a line.  An item starts as a plain action; the first time it is ticked it is
 * swapped for a stateful (boolean) action of the same name, which GTK's menu tracker notices and
 * draws as a check item -- so any item can be ticked later, as on GEM and AppKit.  A pick reaches the
 * toolkit as a menu-select event through the same dispatch as the mouse. */
typedef struct { GMenu* model; GMenu* sub[32]; GMenu* section[32]; int n; } UXGtkMenu;
/* Menu shortcuts: the item's text ends in a tab, "+" for Shift and the key ("Undo\tZ").  The menu
 * shows it (the item's "accel" attribute, display only), and a global-scope shortcut controller on
 * each window that carries the bar handles it.  (The window gathers global controllers into one
 * of its own, so the shortcuts appear twice among its controllers but fire once.) */
#define UX_GTK_MAXKEYS 128
static char gKeyTrigger[UX_GTK_MAXKEYS][32];
static char gKeyAction[UX_GTK_MAXKEYS][40];
static int gKeyN = 0;
static GtkEventController* gKeyCtl[UXGTK_MAXW];
static UXGtkMenu* gMenu;          /* the installed bar, or NULL */
static GSimpleActionGroup* gMenuActions;
static GtkWidget* gMenuBar[UXGTK_MAXW];
static int gMenuBarH[UXGTK_MAXW]; /* its height, which the window grew by */
static void menu_activate_cb(GSimpleAction* a, GVariant* param, gpointer ud)
    {
    (void)param;
    int tag = GPOINTER_TO_INT(ud);
    if (!g_action_get_enabled(G_ACTION(a)))
        return;
    int win = 0;
    for (int h = 1; h < UXGTK_MAXW; h++)
        if (gWin[h] && gtk_window_is_active(gWin[h]))
            win = h;
    if (gMouse)
        gMouse(7, tag / 256, tag % 256, win, 0); /* 7 == UXEventMenuSelect: title, item */
    }
void* ux_gtk_menu_new(void)
    {
    UXGtkMenu* m = (UXGtkMenu*)calloc(1, sizeof *m);
    m->model = g_menu_new();
    gKeyN = 0; /* a new bar: its own shortcuts */

    if (!gMenuActions)
        gMenuActions = g_simple_action_group_new();
    return m;
    }
int ux_gtk_menu_add_title(void* bar, const char* title)
    {
    UXGtkMenu* m = (UXGtkMenu*)bar;
    if (!m || m->n >= 32)
        return -1;
    int t = m->n++;
    m->sub[t] = g_menu_new();
    m->section[t] = g_menu_new();
    g_menu_append_section(m->sub[t], NULL, G_MENU_MODEL(m->section[t]));
    g_menu_append_submenu(m->model, title, G_MENU_MODEL(m->sub[t]));
    return t;
    }
void ux_gtk_menu_add_item(void* bar, int t, int j, const char* text, int checked, int disabled, int sep)
    {
    UXGtkMenu* m = (UXGtkMenu*)bar;
    if (!m || t < 0 || t >= m->n)
        return;
    if (sep)
        {
        m->section[t] = g_menu_new();
        g_menu_append_section(m->sub[t], NULL, G_MENU_MODEL(m->section[t]));
        return;
        }
    char name[32];
    snprintf(name, sizeof name, "m%d_%d", t, j);
    GSimpleAction* a = checked ? g_simple_action_new_stateful(name, NULL, g_variant_new_boolean(TRUE))
                               : g_simple_action_new(name, NULL);
    g_signal_connect(a, "activate", G_CALLBACK(menu_activate_cb), GINT_TO_POINTER(t * 256 + j));
    g_simple_action_set_enabled(a, !disabled);
    g_action_map_add_action(G_ACTION_MAP(gMenuActions), G_ACTION(a));
    g_object_unref(a);
    char detailed[40];
    snprintf(detailed, sizeof detailed, "ux.%s", name);
    const char* tab = strchr(text, '\t');
    if (!tab)
        {
        g_menu_append(m->section[t], text, detailed);
        return;
        }
    char label[256];
    size_t n = (size_t)(tab - text) < sizeof label - 1 ? (size_t)(tab - text) : sizeof label - 1;
    memcpy(label, text, n);
    label[n] = 0;
    int shift = tab[1] == '+';
    int key = shift ? tab[2] : tab[1];
    char accel[32];
    snprintf(accel, sizeof accel, "<Control>%s%c", shift ? "<Shift>" : "",
             (key >= 'A' && key <= 'Z') ? key + 32 : key);
    GMenuItem* mi = g_menu_item_new(label, detailed);
    g_menu_item_set_attribute(mi, "accel", "s", accel);
    g_menu_append_item(m->section[t], mi);
    g_object_unref(mi);
    if (gKeyN < UX_GTK_MAXKEYS)
        {
        snprintf(gKeyTrigger[gKeyN], sizeof gKeyTrigger[0], "%s", accel);
        snprintf(gKeyAction[gKeyN], sizeof gKeyAction[0], "%s", detailed);
        gKeyN++;
        }
    }
/* Put the bar at the top of a window: the window's child becomes a vertical box of the bar and the
 * content, and the window grows by the bar's height so the content keeps its size. */
static void menu_attach(int h)
    {
    if (!gMenu || !gWin[h] || gMenuBar[h])
        return;
    GtkWidget* bar = gtk_popover_menu_bar_new_from_model(G_MENU_MODEL(gMenu->model));
    GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget* fix = GTK_WIDGET(gFix[h]);
    g_object_ref(fix);
    gtk_window_set_child(gWin[h], NULL);
    gtk_box_append(GTK_BOX(box), bar);
    gtk_box_append(GTK_BOX(box), fix);
    g_object_unref(fix);
    gtk_window_set_child(gWin[h], box);
    gtk_widget_insert_action_group(GTK_WIDGET(gWin[h]), "ux", G_ACTION_GROUP(gMenuActions));
    if (gKeyN > 0)
        {
        GtkEventController* keys = gtk_shortcut_controller_new();
        gtk_shortcut_controller_set_scope(GTK_SHORTCUT_CONTROLLER(keys), GTK_SHORTCUT_SCOPE_GLOBAL);
        for (int k = 0; k < gKeyN; k++)
            gtk_shortcut_controller_add_shortcut(GTK_SHORTCUT_CONTROLLER(keys),
                gtk_shortcut_new(gtk_shortcut_trigger_parse_string(gKeyTrigger[k]),
                                 gtk_named_action_new(gKeyAction[k])));
        gtk_widget_add_controller(GTK_WIDGET(gWin[h]), keys);
        gKeyCtl[h] = keys;
        }

    int bh = 0;
    gtk_widget_measure(bar, GTK_ORIENTATION_VERTICAL, -1, NULL, &bh, NULL, NULL);
    int w = 0, hh = 0;
    gtk_window_get_default_size(gWin[h], &w, &hh);
    gtk_window_set_default_size(gWin[h], w, hh + bh);
    gMenuBar[h] = bar;
    gMenuBarH[h] = bh;
    }
void ux_gtk_menu_show(void* bar, int show)
    {
    if (!show || !bar)
        return;
    gMenu = (UXGtkMenu*)bar;
    for (int h = 1; h < UXGTK_MAXW; h++)
        menu_attach(h);
    }
static GSimpleAction* menu_action(int t, int j)
    {
    char name[32];
    snprintf(name, sizeof name, "m%d_%d", t, j);
    return gMenuActions ? G_SIMPLE_ACTION(g_action_map_lookup_action(G_ACTION_MAP(gMenuActions), name)) : NULL;
    }
void ux_gtk_menu_check(int t, int j, int on)
    {
    GSimpleAction* a = menu_action(t, j);
    if (!a)
        return;
    if (g_action_get_state_type(G_ACTION(a)))
        {
        g_simple_action_set_state(a, g_variant_new_boolean(on != 0));
        return;
        }
    if (!on)
        return; /* never ticked: nothing to clear */
    /* first tick: swap in a stateful action of the same name */
    gboolean enabled = g_action_get_enabled(G_ACTION(a));
    char name[32];
    snprintf(name, sizeof name, "m%d_%d", t, j);
    GSimpleAction* b = g_simple_action_new_stateful(name, NULL, g_variant_new_boolean(TRUE));
    g_signal_connect(b, "activate", G_CALLBACK(menu_activate_cb), GINT_TO_POINTER(t * 256 + j));
    g_simple_action_set_enabled(b, enabled);
    g_action_map_remove_action(G_ACTION_MAP(gMenuActions), name);
    g_action_map_add_action(G_ACTION_MAP(gMenuActions), G_ACTION(b));
    g_object_unref(b);
    }
void ux_gtk_menu_enable(int t, int j, int on)
    {
    GSimpleAction* a = menu_action(t, j);
    if (a)
        g_simple_action_set_enabled(a, on != 0);
    }
/* For a gate: activate an item the way a click on it does (through its action), and read an item's
 * state back: bit 0 enabled, bit 1 ticked, -1 no such item.  And the bar a window shows: how many
 * titles its model has (0 = no bar). */
void ux_gtk_menu_test_activate(int t, int j)
    {
    char name[32];
    snprintf(name, sizeof name, "m%d_%d", t, j);
    if (gMenuActions)
        g_action_group_activate_action(G_ACTION_GROUP(gMenuActions), name, NULL);
    }
int ux_gtk_menu_test_state(int t, int j)
    {
    GSimpleAction* a = menu_action(t, j);
    if (!a)
        return -1;
    int st = g_action_get_enabled(G_ACTION(a)) ? 1 : 0;
    GVariant* v = g_action_get_state(G_ACTION(a));
    if (v)
        {
        if (g_variant_get_boolean(v))
            st |= 2;
        g_variant_unref(v);
        }
    return st;
    }
int ux_gtk_menu_test_titles(int h)
    {
    if (h <= 0 || h >= UXGTK_MAXW || !gMenuBar[h])
        return 0;
    GMenuModel* mm = gtk_popover_menu_bar_get_menu_model(GTK_POPOVER_MENU_BAR(gMenuBar[h]));
    return mm ? g_menu_model_get_n_items(mm) : 0;
    }

/* For tests: the accelerator item (t, j) shows in the menu (its GMenu "accel" attribute), copied
 * into buf; 1 if it has one. */
int ux_gtk_menu_test_accel(int t, int j, char* buf, int cap)
    {
    buf[0] = 0;
    if (!gMenu || t < 0 || t >= gMenu->n)
        return 0;
    char want[40];
    snprintf(want, sizeof want, "ux.m%d_%d", t, j);
    GMenuModel* sub = G_MENU_MODEL(gMenu->sub[t]);
    for (int s = 0; s < g_menu_model_get_n_items(sub); s++)
        {
        GMenuModel* sec = g_menu_model_get_item_link(sub, s, G_MENU_LINK_SECTION);
        if (!sec)
            continue;
        for (int i = 0; i < g_menu_model_get_n_items(sec); i++)
            {
            char* act = NULL;
            char* acc = NULL;
            if (g_menu_model_get_item_attribute(sec, i, G_MENU_ATTRIBUTE_ACTION, "s", &act) && strcmp(act, want) == 0)
                {
                int has = g_menu_model_get_item_attribute(sec, i, "accel", "s", &acc);
                if (has)
                    snprintf(buf, cap, "%s", acc);
                g_free(act);
                g_free(acc);
                g_object_unref(sec);
                return has ? 1 : 0;
                }
            g_free(act);
            }
        g_object_unref(sec);
        }
    return 0;
    }
/* For tests: how many shortcuts window h's menu controller holds; with fire >= 0, activate that
 * one's action the way GTK does when its trigger is pressed. */
int ux_gtk_menu_test_shortcuts(int h, int fire)
    {
    if (h <= 0 || h >= UXGTK_MAXW || !gKeyCtl[h])
        return 0;
    GListModel* sc = G_LIST_MODEL(gKeyCtl[h]);
    int n = (int)g_list_model_get_n_items(sc);
    if (fire >= 0 && fire < n)
        {
        GtkShortcut* cut = GTK_SHORTCUT(g_list_model_get_item(sc, (guint)fire));
        gtk_shortcut_action_activate(gtk_shortcut_get_action(cut), 0, GTK_WIDGET(gWin[h]), NULL);
        g_object_unref(cut);
        }
    return n;
    }

/* ── drags and drops between the app's own widgets ────────────────────────────
 * A row dragged out of a table or an outline carries its text as a string marked as the app's own
 * (UX_ROW_MARK first), so a drop knows it from text dragged in from elsewhere.  Each window's
 * GtkFixed takes such rows, and files, as drops; an outline's rows take rows too. */
#define UX_ROW_MARK "\x01uxkit-row\x01"
typedef void (*ux_drop_fn)(const char* text, int win, int x, int y);
static ux_drop_fn gFileDrop, gItemDrop, gItemHover;
typedef int (*tbl_drags_fn)(void*);
static tbl_drags_fn gTblDrags;
typedef const char* (*ol_dragtext_fn)(void*, void*, int);
static ol_dragtext_fn gOlDragText;
void ux_gtk_set_drop_hooks(void* file, void* item, void* hover, void* tableDrags, void* outlineDragText)
    {
    gFileDrop = (ux_drop_fn)file;
    gItemDrop = (ux_drop_fn)item;
    gItemHover = (ux_drop_fn)hover;
    gTblDrags = (tbl_drags_fn)tableDrags;
    gOlDragText = (ol_dragtext_fn)outlineDragText;
    }
/* The row text in a dragged string, or NULL if it is not one of ours. */
static const char* row_text(const char* s)
    {
    size_t m = strlen(UX_ROW_MARK);
    return (s && strncmp(s, UX_ROW_MARK, m) == 0) ? s + m : NULL;
    }
static GdkContentProvider* row_content(const char* text)
    {
    char* s = g_strconcat(UX_ROW_MARK, text, NULL);
    GdkContentProvider* p = gdk_content_provider_new_typed(G_TYPE_STRING, s);
    g_free(s);
    return p;
    }
/* A widget's point in its window's content (the GtkFixed). */
static void content_point(GtkWidget* w, int handle, double x, double y, int* ox, int* oy)
    {
    graphene_point_t in = GRAPHENE_POINT_INIT((float)x, (float)y), out;
    if (gFix[handle] && gtk_widget_compute_point(w, GTK_WIDGET(gFix[handle]), &in, &out))
        {
        *ox = (int)out.x;
        *oy = (int)out.y;
        }
    else
        {
        *ox = (int)x;
        *oy = (int)y;
        }
    }

/* A window's drops: files, and rows dragged out of the app's own tables and outlines, at the point
   in its content.  A row also reports where it is while it is dragged over, and when it leaves. */
static GdkDragAction win_drop_motion(GtkDropTarget* dt, double x, double y, gpointer h)
    {
    const GValue* v = gtk_drop_target_get_value(dt);
    if (v && G_VALUE_HOLDS_STRING(v))
        {
        const char* t = row_text(g_value_get_string(v));
        if (!t)
            return 0;
        if (gItemHover)
            gItemHover(t, GPOINTER_TO_INT(h), (int)x, (int)y);
        }
    return GDK_ACTION_COPY;
    }
static void win_drop_leave(GtkDropTarget* dt, gpointer h)
    {
    const GValue* v = gtk_drop_target_get_value(dt);
    const char* t = v && G_VALUE_HOLDS_STRING(v) ? row_text(g_value_get_string(v)) : NULL;
    if (t && gItemHover)
        gItemHover(t, GPOINTER_TO_INT(h), -1, -1);
    }
static gboolean win_drop(GtkDropTarget* dt, const GValue* v, double x, double y, gpointer h)
    {
    (void)dt;
    int handle = GPOINTER_TO_INT(h);
    if (G_VALUE_HOLDS_STRING(v))
        {
        const char* t = row_text(g_value_get_string(v));
        if (!t || !gItemDrop)
            return FALSE;
        char* copy = g_strdup(t);
        if (gItemHover)
            gItemHover(copy, handle, -1, -1);
        gItemDrop(copy, handle, (int)x, (int)y);
        g_free(copy);
        return TRUE;
        }
    if (G_VALUE_HOLDS(v, GDK_TYPE_FILE_LIST) && gFileDrop)
        {
        for (GSList* l = g_value_get_boxed(v); l; l = l->next)
            {
            char* path = g_file_get_path(G_FILE(l->data));
            if (path)
                gFileDrop(path, handle, (int)x, (int)y);
            g_free(path);
            }
        return TRUE;
        }
    return FALSE;
    }
static void win_drop_target(GtkFixed* fix, int handle)
    {
    GtkDropTarget* dt = gtk_drop_target_new(G_TYPE_INVALID, GDK_ACTION_COPY);
    GType types[2] = {G_TYPE_STRING, GDK_TYPE_FILE_LIST};
    gtk_drop_target_set_gtypes(dt, types, 2);
    gtk_drop_target_set_preload(dt, TRUE);
    g_signal_connect(dt, "enter", G_CALLBACK(win_drop_motion), GINT_TO_POINTER(handle));
    g_signal_connect(dt, "motion", G_CALLBACK(win_drop_motion), GINT_TO_POINTER(handle));
    g_signal_connect(dt, "leave", G_CALLBACK(win_drop_leave), GINT_TO_POINTER(handle));
    g_signal_connect(dt, "drop", G_CALLBACK(win_drop), GINT_TO_POINTER(handle));
    gtk_widget_add_controller(GTK_WIDGET(fix), GTK_EVENT_CONTROLLER(dt));
    }
int ux_gtk_window_create(int x, int y, int w, int h)
    {
    if (gNextH >= UXGTK_MAXW)
        return 0;
    int hh = gNextH++;
    GtkWindow* win = GTK_WINDOW(gtk_window_new());
    gtk_window_set_default_size(win, w, h);
    GtkFixed* fix = GTK_FIXED(gtk_fixed_new());
    gtk_window_set_child(win, GTK_WIDGET(fix));
    GtkWidget* area = gtk_drawing_area_new();
    gtk_widget_set_size_request(area, w, h);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), draw_cb,
                                   GINT_TO_POINTER(hh), NULL);
    gtk_fixed_put(fix, area, 0, 0);
    win_drop_target(fix, hh);
    gWin[hh] = win;
    gFix[hh] = fix;
    gArea[hh] = area;
    GtkEventController* ec = gtk_event_controller_legacy_new();
    g_signal_connect(ec, "event", G_CALLBACK(event_cb), GINT_TO_POINTER(hh));
    gtk_widget_add_controller(GTK_WIDGET(win), ec);
    gLive++;
    menu_attach(hh); /* a menu bar installed before this window opened */
    return hh;
    }
void ux_gtk_window_set_content(int handle, void* fn, void* ud)
    {
    gContent[handle] = (ux_content_fn)fn;
    gContentUd[handle] = ud;
    }
void ux_gtk_window_open(int handle, int x, int y, int w, int h)
    {
    gtk_window_set_default_size(gWin[handle], w, h);
    gtk_widget_set_size_request(gArea[handle], w, h);
    gtk_window_present(gWin[handle]);
    ux_gtk_pump();
    }
void ux_gtk_window_set_title(int handle, const char* s)
    {
    gtk_window_set_title(gWin[handle], s);
    }
void ux_gtk_window_front(int handle)
    {
    gtk_window_present(gWin[handle]);
    }
void ux_gtk_window_close(int handle)
    {
    if (!gWin[handle])
        return;
    gtk_window_destroy(gWin[handle]);
    for (int n = 0; n < UXGTK_MAXN; n++)
        {
        gCtl[handle][n] = NULL;
        gScroll[handle][n] = (GtkScrollRec){0};
        gInDoc[handle][n] = 0;
        }
    ux_gtk_gl_forget(handle);
    gWin[handle] = NULL;
    gMenuBar[handle] = NULL; /* the bar went with its window */
    gMenuBarH[handle] = 0;
    gFix[handle] = NULL;
    gArea[handle] = NULL;
    gContent[handle] = NULL;
    gLive--;
    ux_gtk_pump();
    }
void ux_gtk_window_invalidate(int handle)
    {
    if (gArea[handle])
        gtk_widget_queue_draw(gArea[handle]);
    for (int n = 0; n < UXGTK_MAXN; n++)
        if (gScroll[handle][n].area)
            gtk_widget_queue_draw(gScroll[handle][n].area); /* the scroll documents are surfaces too */
    }
void ux_gtk_content_geometry(int handle, int* w, int* h)
    {
    if (gWin[handle])
        {
        /* the window's size tracks a user's resize; the content is that less the menu bar */
        gtk_window_get_default_size(gWin[handle], w, h);
        *h = *h - gMenuBarH[handle];
        }
    else
        {
        *w = 0;
        *h = 0;
        }
    }
int ux_gtk_native_count(void)
    {
    return gLive;
    }

/* ── native controls ─────────────────────────────────────────────────────── */
static void park(int handle, int node, GtkWidget* w, int x, int y, int ww, int hh)
    {
    gtk_widget_set_size_request(w, ww, hh);
    g_object_set_data(G_OBJECT(w), "ux-handle", GINT_TO_POINTER(handle));
    g_object_set_data(G_OBJECT(w), "ux-node", GINT_TO_POINTER(node));
    gtk_fixed_put(gFix[handle], w, x, y);
    gCtl[handle][node] = w;
    }
static int hOf(GtkWidget* w)
    {
    return GPOINTER_TO_INT(g_object_get_data(G_OBJECT(w), "ux-handle"));
    }
static int nOf(GtkWidget* w)
    {
    return GPOINTER_TO_INT(g_object_get_data(G_OBJECT(w), "ux-node"));
    }

int ux_gtk_has_control(int handle, int node)
    {
    return gCtl[handle][node] != NULL;
    }
void ux_gtk_set_control_frame(int handle, int node, int x, int y, int w, int h)
    {
    GtkWidget* c = gCtl[handle][node];
    if (!c)
        return;
    gtk_widget_set_size_request(c, w, h);
    int sn = gInDoc[handle][node] - 1;
    if (sn >= 0 && gScroll[handle][sn].doc)
        gtk_fixed_move(GTK_FIXED(gScroll[handle][sn].doc), c, x - gScroll[handle][sn].docX, y - gScroll[handle][sn].docY);
    else
        gtk_fixed_move(gFix[handle], c, x, y);
    }
void ux_gtk_set_control_enabled(int handle, int node, int on)
    {
    if (gCtl[handle][node])
        gtk_widget_set_sensitive(gCtl[handle][node], on != 0);
    }
void ux_gtk_set_control_hidden(int handle, int node, int on)
    {
    if (gCtl[handle][node])
        gtk_widget_set_visible(gCtl[handle][node], on == 0);
    }

/* ── native scroll containers ─────────────────────────────────────────────── */
static void (*gScrollContent)(void* sv, int docW, int docH);
void ux_gtk_set_scroll_content(void* fn)
    {
    gScrollContent = (void (*)(void*, int, int))fn;
    }
static void scroll_draw_cb(GtkDrawingArea* a, cairo_t* cr, int w, int h, gpointer ud)
    {
    (void)a;
    GtkScrollRec* r = (GtkScrollRec*)ud;
    if (!gScrollContent || !r->sv)
        return;
    cairo_t* was = gCr;
    gCr = cr;
    gScrollContent(r->sv, w, h);
    gCr = was;
    }
void ux_gtk_make_scroll(int handle, int node, int x, int y, int w, int h, int contentH, void* sv, int docX, int docY)
    {
    if (!gFix[handle] || node < 0 || node >= UXGTK_MAXN || gCtl[handle][node])
        return;
    GtkScrollRec* r = &gScroll[handle][node];
    GtkWidget* sw = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sw), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_size_request(sw, w, h);
    r->doc = gtk_fixed_new();
    r->area = gtk_drawing_area_new();
    r->sv = sv;
    r->docX = docX;
    r->docY = docY;
    gtk_widget_set_size_request(r->area, w, contentH > h ? contentH : h);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(r->area), scroll_draw_cb, r, NULL);
    gtk_fixed_put(GTK_FIXED(r->doc), r->area, 0, 0);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sw), r->doc);
    gtk_fixed_put(gFix[handle], sw, x, y);
    gCtl[handle][node] = sw;
    }
/* the page changed (its height, its place): resize the document and repaint it */
void ux_gtk_scroll_reload(int handle, int node, int w, int h, int contentH, int docX, int docY)
    {
    GtkScrollRec* r = &gScroll[handle][node];
    if (!r->area)
        return;
    r->docX = docX;
    r->docY = docY;
    gtk_widget_set_size_request(r->area, w, contentH > h ? contentH : h);
    gtk_widget_queue_draw(r->area);
    }
void ux_gtk_scroll_set(int handle, int node, int px)
    {
    GtkWidget* sw = gCtl[handle][node];
    if (!sw || !GTK_IS_SCROLLED_WINDOW(sw))
        return;
    GtkAdjustment* a = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(sw));
    double most = gtk_adjustment_get_upper(a) - gtk_adjustment_get_page_size(a);
    gtk_adjustment_set_value(a, px < 0 ? 0 : (px > most ? (most > 0 ? most : 0) : px));
    }
int ux_gtk_scroll_get(int handle, int node)
    {
    GtkWidget* sw = gCtl[handle][node];
    if (!sw || !GTK_IS_SCROLLED_WINDOW(sw))
        return 0;
    return (int)(gtk_adjustment_get_value(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(sw))) + 0.5);
    }
/* A rounded panel (UXScrollView.setCornerRadius / setBorderRGB): the container's own CSS, a radius and
 * a 1px border, and its overflow hidden, so its document and its scrollbar clip to the rounded shape.
 * radius 0 and rgb < 0 drop both. */
void ux_gtk_scroll_style(int handle, int node, int radius, int rgb)
    {
    GtkWidget* sw = gCtl[handle][node];
    if (!sw || !GTK_IS_SCROLLED_WINDOW(sw))
        return;
    char cls[32], css[200];
    snprintf(cls, sizeof cls, "uxscroll-%d-%d", handle, node);
    gtk_widget_add_css_class(sw, cls);
    if (rgb >= 0)
        snprintf(css, sizeof css, ".%s { border-radius: %dpx; border: 1px solid #%06x; }", cls, radius, rgb & 0xFFFFFF);
    else
        snprintf(css, sizeof css, ".%s { border-radius: %dpx; }", cls, radius);
    GtkCssProvider* p = g_object_get_data(G_OBJECT(sw), "ux-css");
    if (!p)
        {
        p = gtk_css_provider_new();
        gtk_style_context_add_provider_for_display(gtk_widget_get_display(sw), GTK_STYLE_PROVIDER(p),
                                                   GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        g_object_set_data_full(G_OBJECT(sw), "ux-css", p, g_object_unref);
        }
    gtk_css_provider_load_from_string(p, css);
    gtk_widget_set_overflow(sw, radius > 0 ? GTK_OVERFLOW_HIDDEN : GTK_OVERFLOW_VISIBLE);
    }
/* A native control inside a scroll view goes into its document, so it scrolls and clips with it. */
void ux_gtk_reparent_to_scroll(int handle, int node, int scrollNode, int ax, int ay)
    {
    GtkWidget* c = gCtl[handle][node];
    GtkScrollRec* r = &gScroll[handle][scrollNode];
    if (!c || !r->doc)
        return;
    if (gtk_widget_get_parent(c) != r->doc)
        {
        g_object_ref(c);
        gtk_widget_unparent(c);
        gtk_fixed_put(GTK_FIXED(r->doc), c, ax - r->docX, ay - r->docY);
        g_object_unref(c);
        }
    else
        gtk_fixed_move(GTK_FIXED(r->doc), c, ax - r->docX, ay - r->docY);
    gInDoc[handle][node] = (unsigned short)(scrollNode + 1);
    }
/* Whether a point (window coordinates) is over a scroll container's DOCUMENT (1), elsewhere (0), or
 * on the container's own scrollbar or a native control in it (-1), which handle it themselves.  The
 * point is not changed: it goes on as it shows on screen, and the toolkit adds the scroll offset in
 * its own hit test (UXWindow.hitScrolled), so a real click and a synthetic one agree. */
static int scroll_doc_point(int handle, double wx, double wy, double* x, double* y)
    {
    for (int n = 0; n < UXGTK_MAXN; n++)
        {
        GtkScrollRec* r = &gScroll[handle][n];
        GtkWidget* sw = gCtl[handle][n];
        if (!r->area || !sw || !gtk_widget_get_mapped(sw))
            continue;
        graphene_point_t wp = GRAPHENE_POINT_INIT((float)wx, (float)wy), sp, dp;
        if (!gtk_widget_compute_point(GTK_WIDGET(gWin[handle]), sw, &wp, &sp))
            continue;
        if (sp.x < 0 || sp.y < 0 || sp.x >= gtk_widget_get_width(sw) || sp.y >= gtk_widget_get_height(sw))
            continue;
        GtkWidget* hit = gtk_widget_pick(sw, sp.x, sp.y, GTK_PICK_DEFAULT);
        if (hit != r->area)
            return -1; /* the scrollbar, or a native control in the document: theirs */
        (void)dp;
        return 1; /* on the document: the point stays as it shows, the toolkit adds the offset */
        }
    return 0;
    }
/* Test: a click at (x, y) of the window's content as it is on screen, taken the way a real one is
 * (to window coordinates and back, the scrollbar and native controls left to themselves). */
void ux_gtk_test_click_at(int handle, int x, int y)
    {
    if (!gWin[handle] || !gArea[handle])
        return;
    graphene_point_t ap = GRAPHENE_POINT_INIT((float)x, (float)y), wp;
    if (!gtk_widget_compute_point(gArea[handle], GTK_WIDGET(gWin[handle]), &ap, &wp))
        return;
    double tx = x, ty = y;
    if (scroll_doc_point(handle, wp.x, wp.y, &tx, &ty) < 0)
        return; /* on the container's own scrollbar */
    ux_gtk_input(handle, 1, 1, tx, ty, 0);
    ux_gtk_input(handle, 2, 1, tx, ty, 0);
    }
/* Test: a scroll container's document (its drawing area), to read back what it painted. */
int ux_gtk_test_scroll_native(int handle, int node)
    {
    return gScroll[handle][node].area && gCtl[handle][node] && GTK_IS_SCROLLED_WINDOW(gCtl[handle][node]) ? 1 : 0;
    }
int ux_gtk_test_in_scroll_doc(int handle, int node, int scrollNode)
    {
    GtkWidget* c = gCtl[handle][node];
    return c && gScroll[handle][scrollNode].doc && gtk_widget_get_parent(c) == gScroll[handle][scrollNode].doc ? 1 : 0;
    }

static void clicked_cb(GtkButton* b, gpointer ud)
    {
    if (gFire)
        gFire(hOf(GTK_WIDGET(b)), nOf(GTK_WIDGET(b)));
    }
void ux_gtk_make_button(int handle, int node, int x, int y, int w, int h, const char* title)
    {
    GtkWidget* b = gtk_button_new_with_label(title);
    g_signal_connect(b, "clicked", G_CALLBACK(clicked_cb), NULL);
    park(handle, node, b, x, y, w, h);
    }
void ux_gtk_make_label(int handle, int node, int x, int y, int w, int h, const char* text)
    {
    GtkWidget* l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 0.0f);
    park(handle, node, l, x, y, w, h);
    }

/* Set while the driver pushes a model's value into a widget: GTK emits toggled, value-changed and
 * notify::selected for a programmatic change too, which must not come back as the user's (it would
 * fire the control's action every time the app set it). */
static int gValueMute;
static void toggled_cb(GtkCheckButton* c, gpointer ud)
    {
    if (gValue && !gValueMute)
        gValue(hOf(GTK_WIDGET(c)), nOf(GTK_WIDGET(c)),
               gtk_check_button_get_active(c) ? 1 : 0);
    }
void ux_gtk_make_check(int handle, int node, int x, int y, int w, int h,
                       const char* title, int on)
    {
    GtkWidget* c = gtk_check_button_new_with_label(title);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(c), on != 0);
    g_signal_connect(c, "toggled", G_CALLBACK(toggled_cb), NULL);
    park(handle, node, c, x, y, w, h);
    }
/* A radio: GTK 4 has no radio widget of its own -- a GtkCheckButton in a group IS one, drawn round.
 * Grouped with the radio at `leader`; one with no leader gets a hidden partner of its own, so a lone
 * radio still looks like a radio and not a check box. */
void ux_gtk_make_radio(int handle, int node, int x, int y, int w, int h, const char* title, int on, int leader)
    {
    GtkWidget* c = gtk_check_button_new_with_label(title);
    GtkWidget* lead = (leader >= 0 && leader < UXGTK_MAXN) ? gCtl[handle][leader] : NULL;
    if (lead && GTK_IS_CHECK_BUTTON(lead))
        gtk_check_button_set_group(GTK_CHECK_BUTTON(c), GTK_CHECK_BUTTON(lead));
    else
        {
        GtkWidget* partner = gtk_check_button_new();
        g_object_ref_sink(partner); /* never shown: only its group membership matters */
        gtk_check_button_set_group(GTK_CHECK_BUTTON(c), GTK_CHECK_BUTTON(partner));
        g_object_set_data_full(G_OBJECT(c), "ux-radio-partner", partner, g_object_unref);
        }
    gtk_check_button_set_active(GTK_CHECK_BUTTON(c), on != 0);
    g_signal_connect(c, "toggled", G_CALLBACK(toggled_cb), NULL);
    park(handle, node, c, x, y, w, h);
    }
/* For a gate: a toggle's native state -- bit 0 active, bit 1 drawn as a radio, bit 2 a check
 * button at all; and switching one on the way a click does (GTK's own set_active, so the toggled
 * signal and the group's exclusion run as for a person). */
int ux_gtk_test_toggle(int handle, int node)
    {
    GtkWidget* c = gCtl[handle][node];
    if (!c || !GTK_IS_CHECK_BUTTON(c))
        return 0;
    int st = 4 | (gtk_check_button_get_active(GTK_CHECK_BUTTON(c)) ? 1 : 0);
    /* what GTK draws: a grouped check button's indicator is the CSS node "radio", a lone one "check" */
    for (GtkWidget* k = gtk_widget_get_first_child(c); k; k = gtk_widget_get_next_sibling(k))
        if (strcmp(gtk_widget_get_css_name(k), "radio") == 0)
            st |= 2;
    return st;
    }
/* For a gate: is the native control at (handle, node) sensitive (enabled), as GTK sees it? */
int ux_gtk_test_sensitive(int handle, int node)
    {
    GtkWidget* c = gCtl[handle][node];
    return c ? (gtk_widget_is_sensitive(c) ? 1 : 0) : -1;
    }
void ux_gtk_test_activate_toggle(int handle, int node)
    {
    GtkWidget* c = gCtl[handle][node];
    if (c && GTK_IS_CHECK_BUTTON(c))
        gtk_check_button_set_active(GTK_CHECK_BUTTON(c), TRUE);
    }
void ux_gtk_set_check(int handle, int node, int on)
    {
    GtkWidget* c = gCtl[handle][node];
    gValueMute = 1;
    if (GTK_IS_CHECK_BUTTON(c) && gtk_check_button_get_active(GTK_CHECK_BUTTON(c)) != (on != 0))
        gtk_check_button_set_active(GTK_CHECK_BUTTON(c), on != 0);
    gValueMute = 0;
    }

static void range_cb(GtkRange* r, gpointer ud)
    {
    if (gValue && !gValueMute)
        gValue(hOf(GTK_WIDGET(r)), nOf(GTK_WIDGET(r)),
               (int)(gtk_range_get_value(r) + 0.5));
    }
void ux_gtk_make_slider(int handle, int node, int x, int y, int w, int h,
                        int lo, int hi, int val)
    {
    GtkWidget* s = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, lo, hi, 1);
    gtk_scale_set_draw_value(GTK_SCALE(s), FALSE);
    gtk_range_set_value(GTK_RANGE(s), val);
    g_signal_connect(s, "value-changed", G_CALLBACK(range_cb), NULL);
    park(handle, node, s, x, y, w, h);
    }
void ux_gtk_set_slider_value(int handle, int node, int val)
    {
    GtkWidget* c = gCtl[handle][node];
    gValueMute = 1;
    if (GTK_IS_RANGE(c) && (int)(gtk_range_get_value(GTK_RANGE(c)) + 0.5) != val)
        gtk_range_set_value(GTK_RANGE(c), val);
    gValueMute = 0;
    }

static void spin_cb(GtkSpinButton* s, gpointer ud)
    {
    if (gValue && !gValueMute)
        gValue(hOf(GTK_WIDGET(s)), nOf(GTK_WIDGET(s)),
               gtk_spin_button_get_value_as_int(s));
    }
void ux_gtk_make_stepper(int handle, int node, int x, int y, int w, int h,
                         int lo, int hi, int step, int wraps, int val)
    {
    GtkWidget* s = gtk_spin_button_new_with_range(lo, hi, step > 0 ? step : 1);
    gtk_spin_button_set_wrap(GTK_SPIN_BUTTON(s), wraps != 0);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(s), val);
    g_signal_connect(s, "value-changed", G_CALLBACK(spin_cb), NULL);
    park(handle, node, s, x, y, w, h);
    }
void ux_gtk_set_stepper_value(int handle, int node, int val)
    {
    GtkWidget* c = gCtl[handle][node];
    if (GTK_IS_SPIN_BUTTON(c))
        {
        gValueMute = 1;
        if (gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(c)) != val)
            gtk_spin_button_set_value(GTK_SPIN_BUTTON(c), val);
        gValueMute = 0;
        }
    }

void ux_gtk_make_progress(int handle, int node, int x, int y, int w, int h, int mille)
    {
    GtkWidget* p = gtk_progress_bar_new();
    gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(p), mille / 1000.0);
    park(handle, node, p, x, y, w, h);
    }
void ux_gtk_set_progress(int handle, int node, int mille, int indeterminate)
    {
    GtkWidget* c = gCtl[handle][node];
    if (GTK_IS_PROGRESS_BAR(c))
        gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(c), mille / 1000.0);
    }

static void dropdown_cb(GObject* d, GParamSpec* ps, gpointer ud)
    {
    if (gValue && !gValueMute)
        gValue(hOf(GTK_WIDGET(d)), nOf(GTK_WIDGET(d)),
               (int)gtk_drop_down_get_selected(GTK_DROP_DOWN(d)));
    }
static GtkStringList* gPopupItems[UXGTK_MAXW * UXGTK_MAXN];
void ux_gtk_make_popup(int handle, int node, int x, int y, int w, int h)
    {
    GtkStringList* sl = gtk_string_list_new(NULL);
    gPopupItems[handle * UXGTK_MAXN + node] = sl;
    GtkWidget* d = gtk_drop_down_new(G_LIST_MODEL(sl), NULL);
    g_signal_connect(d, "notify::selected", G_CALLBACK(dropdown_cb), NULL);
    park(handle, node, d, x, y, w, h);
    }
void ux_gtk_popup_add_item(int handle, int node, const char* title)
    {
    gtk_string_list_append(gPopupItems[handle * UXGTK_MAXN + node], title);
    }
void ux_gtk_popup_select(int handle, int node, int i)
    {
    GtkWidget* c = gCtl[handle][node];
    gValueMute = 1;
    if (GTK_IS_DROP_DOWN(c) && i >= 0 && (int)gtk_drop_down_get_selected(GTK_DROP_DOWN(c)) != i)
        gtk_drop_down_set_selected(GTK_DROP_DOWN(c), i);
    gValueMute = 0;
    }

/* segmented: linked GtkToggleButtons in one group — the GTK idiom for a
 * segment row (the "linked" style class fuses them visually) */
static int gSegMute;
static void seg_cb(GtkToggleButton* t, gpointer ud)
    {
    if (gSegMute || !gtk_toggle_button_get_active(t))
        return;
    GtkWidget* box = gtk_widget_get_parent(GTK_WIDGET(t));
    if (gValue)
        gValue(hOf(box), nOf(box),
               GPOINTER_TO_INT(g_object_get_data(G_OBJECT(t), "ux-seg")));
    }
void ux_gtk_make_segmented(int handle, int node, int x, int y, int w, int h, int nseg)
    {
    GtkWidget* box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(box, "linked");
    GtkWidget* first = NULL;
    for (int i = 0; i < nseg; i++)
        {
        GtkWidget* t = gtk_toggle_button_new_with_label("");
        g_object_set_data(G_OBJECT(t), "ux-seg", GINT_TO_POINTER(i));
        if (!first)
            first = t;
        else
            gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(t), GTK_TOGGLE_BUTTON(first));
        gtk_widget_set_hexpand(t, TRUE);
        g_signal_connect(t, "toggled", G_CALLBACK(seg_cb), NULL);
        gtk_box_append(GTK_BOX(box), t);
        }
    park(handle, node, box, x, y, w, h);
    }
static GtkWidget* seg_nth(int handle, int node, int i)
    {
    GtkWidget* box = gCtl[handle][node];
    if (!box)
        return NULL;
    GtkWidget* c = gtk_widget_get_first_child(box);
    while (c && i-- > 0)
        c = gtk_widget_get_next_sibling(c);
    return c;
    }
void ux_gtk_seg_set_label(int handle, int node, int seg, const char* label)
    {
    GtkWidget* t = seg_nth(handle, node, seg);
    if (t)
        gtk_button_set_label(GTK_BUTTON(t), label);
    }
void ux_gtk_seg_select(int handle, int node, int seg)
    {
    GtkWidget* t = seg_nth(handle, node, seg);
    gSegMute = 1; /* programmatic selection must not fire */
    if (t)
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(t), TRUE);
    gSegMute = 0;
    }
/* Test: a native control's value as GTK holds it -- a check 0/1, a range's or spin button's value,
 * a progress bar in permille, a drop-down's selection (-9999: none) */
int ux_gtk_test_native_value(int handle, int node)
    {
    GtkWidget* c = gCtl[handle][node];
    if (GTK_IS_CHECK_BUTTON(c))
        return gtk_check_button_get_active(GTK_CHECK_BUTTON(c)) ? 1 : 0;
    if (GTK_IS_SPIN_BUTTON(c))
        return gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(c));
    if (GTK_IS_RANGE(c))
        return (int)(gtk_range_get_value(GTK_RANGE(c)) + 0.5);
    if (GTK_IS_PROGRESS_BAR(c))
        return (int)(gtk_progress_bar_get_fraction(GTK_PROGRESS_BAR(c)) * 1000.0 + 0.5);
    if (GTK_IS_DROP_DOWN(c))
        return (int)gtk_drop_down_get_selected(GTK_DROP_DOWN(c));
    return -9999;
    }
/* the tests' segment tap: the real toggled path, exactly a user's click */
void ux_gtk_test_seg_click(int handle, int node, int seg)
    {
    GtkWidget* t = seg_nth(handle, node, seg);
    if (t)
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(t), TRUE);
    }

static void entry_cb(GtkEditable* e, gpointer ud)
    {
    GtkWidget* w = GTK_WIDGET(e);
    int handle = hOf(w), node = nOf(w);
    char* buf = gFieldBuf[handle * UXGTK_MAXN + node];
    int cap = gFieldCap[handle * UXGTK_MAXN + node];
    if (buf && cap > 0)
        {
        const char* t = gtk_editable_get_text(e);
        strncpy(buf, t ? t : "", cap - 1);
        buf[cap - 1] = 0;
        }
    if (gField)
        gField(handle, node);
    }
/* Return in a GtkEntry: "activate" fires for that key alone, so no movement test is needed. */
static void entry_activate_cb(GtkWidget* w, gpointer ud)
    {
    (void)ud;
    if (gFieldSubmit)
        gFieldSubmit(hOf(w), nOf(w));
    }
void ux_gtk_make_field(int handle, int node, int x, int y, int w, int h,
                       char* buf, int cap, int secure)
    {
    GtkWidget* e = secure ? gtk_password_entry_new() : gtk_entry_new();
    if (buf && buf[0])
        gtk_editable_set_text(GTK_EDITABLE(e), buf);
    gFieldBuf[handle * UXGTK_MAXN + node] = buf;
    gFieldCap[handle * UXGTK_MAXN + node] = cap;
    g_signal_connect(e, "changed", G_CALLBACK(entry_cb), NULL);
    g_signal_connect(e, "activate", G_CALLBACK(entry_activate_cb), NULL);
    park(handle, node, e, x, y, w, h);
    }
void ux_gtk_update_field(int handle, int node)
    {
    GtkWidget* c = gCtl[handle][node];
    char* buf = gFieldBuf[handle * UXGTK_MAXN + node];
    if (c && GTK_IS_EDITABLE(c) && buf)
        gtk_editable_set_text(GTK_EDITABLE(c), buf);
    }

/* ── drawing ops (the cairo of the draw in flight) ───────────────────────── */
static void setRGB(int r, int g, int b)
    {
    cairo_set_source_rgb(gCr, r / 255.0, g / 255.0, b / 255.0);
    }
/* alpha is the straight 0..255 value; cairo blends every fill and stroke source-over, so a
   translucent primitive composites with what is under it.  a == 255 is the opaque case. */
static void setRGBA(int r, int g, int b, int a)
    {
    cairo_set_source_rgba(gCr, r / 255.0, g / 255.0, b / 255.0, a / 255.0);
    }
/* drawPixels: the region is converted to cairo's ARGB32 -- premultiplied, native-endian words --
 * in a surface of its own, then painted scaled (bilinear) with the overall alpha.  Converted per call
 * and region only, so an icon out of a large atlas costs only its own pixels.  `fmt` 1 is UXPIX_ARGB32
 * (0xAARRGGBB words, B,G,R,A in memory), 0 is UXPIX_RGBA (bytes R,G,B,A). */
void ux_gtk_draw_pixels(const unsigned char* data, int w, int h, int fmt, int sx, int sy, int sw, int sh,
                        int dx, int dy, int dw, int dh, int alpha)
    {
    if (!gCr || !data || alpha <= 0 || dw <= 0 || dh <= 0)
        return;
    if (sx < 0) sx = 0;
    if (sy < 0) sy = 0;
    if (sx + sw > w) sw = w - sx;
    if (sy + sh > h) sh = h - sy;
    if (sw <= 0 || sh <= 0)
        return;
    cairo_surface_t* s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, sw, sh);
    if (cairo_surface_status(s) != CAIRO_STATUS_SUCCESS)
        return;
    cairo_surface_flush(s);
    unsigned char* out = cairo_image_surface_get_data(s);
    int stride = cairo_image_surface_get_stride(s);
    for (int y = 0; y < sh; y++)
        {
        unsigned int* row = (unsigned int*)(out + (size_t)y * stride);
        for (int x = 0; x < sw; x++)
            {
            const unsigned char* q = data + ((size_t)(sy + y) * w + (sx + x)) * 4;
            unsigned int r = fmt == 1 ? q[2] : q[0], g = q[1], b = fmt == 1 ? q[0] : q[2], a = q[3];
            row[x] = (a << 24) | (((r * a + 127) / 255) << 16) | (((g * a + 127) / 255) << 8) | ((b * a + 127) / 255);
            }
        }
    cairo_surface_mark_dirty(s);
    cairo_save(gCr);
    cairo_translate(gCr, dx, dy);
    cairo_scale(gCr, (double)dw / sw, (double)dh / sh);
    cairo_set_source_surface(gCr, s, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(gCr), CAIRO_FILTER_BILINEAR);
    cairo_pattern_set_extend(cairo_get_source(gCr), CAIRO_EXTEND_PAD);
    cairo_rectangle(gCr, 0, 0, sw, sh);
    cairo_clip(gCr);
    cairo_paint_with_alpha(gCr, alpha >= 255 ? 1.0 : alpha / 255.0);
    cairo_restore(gCr);
    cairo_surface_destroy(s);
    }
void ux_gtk_fill(int x, int y, int w, int h, int r, int g, int b, int a)
    {
    if (!gCr)
        return;
    setRGBA(r, g, b, a);
    cairo_rectangle(gCr, x, y, w, h);
    cairo_fill(gCr);
    }
/* CLEAR: erase the rect whatever is under it, so a compositing layer starts empty.  A source-over
   fill at alpha 0 would paint nothing instead of emptying. */
void ux_gtk_clear(int x, int y, int w, int h)
    {
    if (!gCr)
        return;
    cairo_save(gCr);
    cairo_set_operator(gCr, CAIRO_OPERATOR_CLEAR);
    cairo_rectangle(gCr, x, y, w, h);
    cairo_fill(gCr);
    cairo_restore(gCr);
    }
void ux_gtk_tri(int x0, int y0, int x1, int y1, int x2, int y2, int r, int g, int b)
    {
    if (!gCr)
        return;
    setRGB(r, g, b);
    cairo_move_to(gCr, x0, y0);
    cairo_line_to(gCr, x1, y1);
    cairo_line_to(gCr, x2, y2);
    cairo_close_path(gCr);
    cairo_fill(gCr);
    }
void ux_gtk_poly(short* xy, int n, int r, int g, int b, int a)
    {
    if (!gCr || n < 3)
        return;
    setRGBA(r, g, b, a);
    cairo_move_to(gCr, xy[0], xy[1]);
    for (int i = 1; i < n; i++)
        cairo_line_to(gCr, xy[i * 2], xy[i * 2 + 1]);
    cairo_close_path(gCr);
    cairo_fill(gCr);
    }
/* The distance from the top of the line — the y a drawText is handed — down to the baseline: cairo's
 * ascent for the face and size, with 0.8 of the em as the floor for a face that reports nothing.  The
 * three entries below and ux_gtk_text_ascent all come through it, so the number a caller converts a
 * canvas baseline with cannot drift from where the shim puts the baseline.  It used to be the em size,
 * which sat GTK text a few pixels lower than every other backend's top-of-line; cairo reports an
 * ascent of 18 at size 24, and the ink lands where that says (test_gtk_real checks the row). */
static int gtk_line_ascent(cairo_t* c, const char* family, int size, int weight, int italic);
void ux_gtk_text(const char* s, int x, int y, int r, int g, int b, int a, int size)
    {
    if (!gCr)
        return;
    setRGBA(r, g, b, a);
    cairo_move_to(gCr, x, y + gtk_line_ascent(gCr, "", size, 400, 0)); /* top-left in, baseline out */
    cairo_show_text(gCr, s);
    }
void ux_gtk_text_weight(const char* s, int x, int y, const char* family, int size,
                        int weight, int italic, int r, int g, int b, int a)
    {
    if (!gCr)
        return;
    setRGBA(r, g, b, a);
    cairo_move_to(gCr, x, y + gtk_line_ascent(gCr, family, size, weight, italic));
    cairo_show_text(gCr, s);
    }
void ux_gtk_text_font(const char* s, int x, int y, int r, int g, int b,
                      const char* family, int size, int bold, int italic)
    {
    if (!gCr)
        return;
    setRGB(r, g, b);
    cairo_move_to(gCr, x, y + gtk_line_ascent(gCr, family, size, bold ? 700 : 400, italic));
    cairo_show_text(gCr, s);
    }
/* Build one op run into the cairo context and stroke it.  A dashed stroke needs nothing special here:
 * cairo restarts the dash phase at every MOVE, which is the browser rule — measured, not assumed, by
 * test_gtk_real's two-subpath dash (the two rows come back identical to the pixel with the run stroked
 * whole).  */
static void gtk_stroke_run(const int* ops, int n)
    {
    int i = 0;
    while (i < n)
        {
        int op = ops[i++];
        if (op == 0 && i + 1 < n + 1)
            {
            cairo_move_to(gCr, ops[i], ops[i + 1]);
            i += 2;
            }
        else if (op == 1 && i + 1 < n + 1)
            {
            cairo_line_to(gCr, ops[i], ops[i + 1]);
            i += 2;
            }
        else if (op == 2 && i + 5 < n + 1)
            {
            cairo_curve_to(gCr, ops[i], ops[i + 1], ops[i + 2], ops[i + 3], ops[i + 4], ops[i + 5]);
            i += 6;
            }
        else if (op == 3)
            {
            cairo_close_path(gCr);
            }
        else
            {
            break;
            }
        }
    cairo_stroke(gCr);
    }
/* Ints occupied by the op at i, or 0 if it runs off the end. */
/* The width is in device pixels and may be fractional — cairo_set_line_width is a double, so a
 * 1.536-px border is exactly that.
 * dash/ndash/phase: the on/off run in device pixels and the offset into it (ndash 0 = solid).  cairo
 * takes a negative offset the same way Canvas2D takes a negative lineDashOffset: the run starts
 * before its beginning.  */
void ux_gtk_stroke_path(int* ops, int n, double width, int startCap, int endCap, int join,
                        int* dash, int ndash, int phase, int r, int g, int b, int a)
    {
    if (!gCr || n <= 0 || width <= 0.0)
        return;
    setRGBA(r, g, b, a);
    cairo_set_line_width(gCr, width);
    /* join: 0 miter, 1 round, 2 bevel (UXJOIN_*) */
    cairo_set_line_join(gCr, join == 0   ? CAIRO_LINE_JOIN_MITER
                             : join == 2 ? CAIRO_LINE_JOIN_BEVEL
                                         : CAIRO_LINE_JOIN_ROUND);
    int cap = startCap > endCap ? startCap : endCap;
    cairo_set_line_cap(gCr, cap == 1   ? CAIRO_LINE_CAP_ROUND
                            : cap == 2 ? CAIRO_LINE_CAP_SQUARE
                                       : CAIRO_LINE_CAP_BUTT);
    int dashed = ndash > 0;
    if (dashed)
        {
        double pat[8];
        int k = ndash > 8 ? 8 : ndash;
        for (int j = 0; j < k; j++)
            {
            pat[j] = dash[j] > 0 ? (double)dash[j] : 1.0;
            }
        cairo_set_dash(gCr, pat, k, (double)phase);
        }
    else
        {
        cairo_set_dash(gCr, NULL, 0, 0.0);
        }
    gtk_stroke_run(ops, n);
    }
/* Text metrics and the drawing calls share one face, so a measure and a paint can never disagree:
 * the toy font API has two weights, so the CSS scale folds at semibold here exactly as it does in
 * ux_gtk_text_weight. */
static void gtk_set_font(cairo_t* c, const char* family, int size, int weight, int italic)
    {
    cairo_select_font_face(c, family && family[0] ? family : "sans-serif",
                           italic ? CAIRO_FONT_SLANT_ITALIC : CAIRO_FONT_SLANT_NORMAL,
                           weight >= 600 ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(c, size > 0 ? size : 13);
    }
static int gtk_line_ascent(cairo_t* c, const char* family, int size, int weight, int italic)
    {
    gtk_set_font(c, family, size, weight, italic);
    cairo_font_extents_t fe;
    cairo_font_extents(c, &fe);   /* void: an unset font reports zeros, which the floor below covers */
    if (fe.ascent <= 0)
        {
        return (int)((size > 0 ? size : 13) * 0.8);
        }
    return (int)(fe.ascent + 0.5);
    }
int ux_gtk_text_width_weight(const char* s, const char* family, int size, int weight, int italic)
    {
    static cairo_surface_t* ms;
    static cairo_t* mc;
    if (!mc)
        {
        ms = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
        mc = cairo_create(ms);
        }
    gtk_set_font(mc, family, size, weight, italic);
    cairo_text_extents_t te;
    cairo_text_extents(mc, s, &te);
    return (int)(te.x_advance + 0.5);
    }
/* The FACE's ascent: how far below the top of the line the baseline sits — the same function the text
 * entries place with, so the measure answers with the distance a paint is offset by. */
int ux_gtk_text_ascent(const char* family, int size, int weight, int italic)
    {
    static cairo_surface_t* as2;
    static cairo_t* ac;
    if (!ac)
        {
        as2 = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
        ac = cairo_create(as2);
        }
    return gtk_line_ascent(ac, family, size, weight, italic);
    }
int ux_gtk_text_width(const char* s, const char* family, int size, int bold, int italic)
    {
    static cairo_surface_t* ms;
    static cairo_t* mc;
    if (!mc)
        {
        ms = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
        mc = cairo_create(ms);
        }
    cairo_select_font_face(mc, family && family[0] ? family : "sans-serif",
                           italic ? CAIRO_FONT_SLANT_ITALIC : CAIRO_FONT_SLANT_NORMAL,
                           bold ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(mc, size > 0 ? size : 13);
    cairo_text_extents_t te;
    cairo_text_extents(mc, s, &te);
    return (int)(te.x_advance + 0.5);
    }

/* ── time / zone (GLib owns the clock and the rules) ─────────────────────── */
int ux_gtk_now_ms(void)
    {
    return (int)((g_get_monotonic_time() / 1000) & 0x7FFFFFFF);
    }
void ux_gtk_now_utc(int* out7)
    {
    GDateTime* d = g_date_time_new_now_utc();
    out7[0] = g_date_time_get_year(d);
    out7[1] = g_date_time_get_month(d);
    out7[2] = g_date_time_get_day_of_month(d);
    out7[3] = g_date_time_get_hour(d);
    out7[4] = g_date_time_get_minute(d);
    out7[5] = g_date_time_get_second(d);
    out7[6] = g_date_time_get_microsecond(d);
    g_date_time_unref(d);
    }
int ux_gtk_local_offset_minutes(void)
    {
    GDateTime* d = g_date_time_new_now_local();
    int m = (int)(g_date_time_get_utc_offset(d) / G_TIME_SPAN_MINUTE);
    g_date_time_unref(d);
    return m;
    }

/* ── settings: one GKeyFile per domain under the user config dir ─────────── */
/* The Linux idiom without the schema ceremony: GSettings requires compiled
 * schemas installed system-side, which an app-defined, string-keyed store
 * cannot provide — a keyfile per domain in XDG config is what desktop apps
 * without schemas actually do.  UX_GTK_SETTINGS_DIR overrides the base for
 * hermetic tests. */
static char* setting_path(const char* domain)
    {
    const char* base = g_getenv("UX_GTK_SETTINGS_DIR");
    gchar* dir = (base && *base) ? g_strdup(base)
                                 : g_build_filename(g_get_user_config_dir(), "uxkit", NULL);
    g_mkdir_with_parents(dir, 0700);
    char* p = g_strdup_printf("%s/%s.conf", dir, domain);
    g_free(dir);
    return p;
    }
int ux_gtk_setting_get(const char* domain, const char* key, char* out, int cap)
    {
    char* path = setting_path(domain);
    GKeyFile* kf = g_key_file_new();
    int ok = 0;
    if (g_key_file_load_from_file(kf, path, G_KEY_FILE_NONE, NULL))
        {
        gchar* v = g_key_file_get_string(kf, "settings", key, NULL);
        if (v)
            {
            g_strlcpy(out, v, cap);
            g_free(v);
            ok = 1;
            }
        }
    g_key_file_free(kf);
    g_free(path);
    return ok;
    }
int ux_gtk_setting_set(const char* domain, const char* key, const char* value)
    {
    char* path = setting_path(domain);
    GKeyFile* kf = g_key_file_new();
    g_key_file_load_from_file(kf, path, G_KEY_FILE_KEEP_COMMENTS, NULL);
    g_key_file_set_string(kf, "settings", key, value);
    int ok = g_key_file_save_to_file(kf, path, NULL) ? 1 : 0;
    g_key_file_free(kf);
    g_free(path);
    return ok;
    }
int ux_gtk_setting_remove(const char* domain, const char* key)
    {
    char* path = setting_path(domain);
    GKeyFile* kf = g_key_file_new();
    int ok = 0;
    if (g_key_file_load_from_file(kf, path, G_KEY_FILE_KEEP_COMMENTS, NULL) && g_key_file_remove_key(kf, "settings", key, NULL))
        {
        ok = g_key_file_save_to_file(kf, path, NULL) ? 1 : 0;
        }
    g_key_file_free(kf);
    g_free(path);
    return ok;
    }

/* ── the offscreen proof rig ─────────────────────────────────────────────── */
static cairo_surface_t* gShot;
void ux_gtk_render(int handle)
    {
    int w = 0, h = 0;
    ux_gtk_content_geometry(handle, &w, &h);
    if (w <= 0 || h <= 0 || !gContent[handle])
        return;
    if (gShot)
        cairo_surface_destroy(gShot);
    gShot = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    cairo_t* cr = cairo_create(gShot);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_paint(cr);
    gCr = cr;
    gContent[handle](handle, 0, 0, w, h, gContentUd[handle]);
    gCr = NULL;
    cairo_destroy(cr);
    cairo_surface_flush(gShot);
    }
/* The capture rig: the REAL widget scene — native controls included — via
 * GtkWidgetPaintable -> GskRenderNode -> cairo.  The window must be
 * presented and allocated, so pump the loop dry first. */
static gboolean ux_gtk_heartbeat(gpointer ud)
    {
    (void)ud;
    return G_SOURCE_CONTINUE;
    }
void ux_gtk_render_scene(int handle)
    {
    if (!gWin[handle] || !gFix[handle])
        return;
    while (g_main_context_iteration(NULL, FALSE))
        {
        }
    /* the widget must be ALLOCATED or the paintable snapshots nothing — and
     * allocation rides the frame clock, which is not a "pending" source, so
     * the dry pump can miss it.  Block until the clock has ticked us a size.
     * The 5ms heartbeat keeps every blocking iteration BOUNDED: with the app
     * denied window-server frames (inactive/background), one TRUE iteration
     * with no other pending source blocks forever. */
    guint beat = g_timeout_add(5, ux_gtk_heartbeat, NULL);
    int spins = 0;
    while (gtk_widget_get_width(GTK_WIDGET(gFix[handle])) <= 0 && spins < 120)
        {
        g_main_context_iteration(NULL, TRUE);
        spins++;
        }
    int w = 0, h = 0;
    ux_gtk_content_geometry(handle, &w, &h);
    if (w <= 0 || h <= 0)
        return;
    GdkPaintable* p = gtk_widget_paintable_new(GTK_WIDGET(gFix[handle]));
    /* the paintable mirrors RENDERED frames: queue a draw and let the frame
     * clock actually paint one before asking for the node */
    gtk_widget_queue_draw(GTK_WIDGET(gFix[handle]));
    for (int i = 0; i < 30; i++)
        {
        g_main_context_iteration(NULL, TRUE);
        }
    g_source_remove(beat);
    GtkSnapshot* snap = gtk_snapshot_new();
    gdk_paintable_snapshot(p, GDK_SNAPSHOT(snap), w, h);
    GskRenderNode* node = gtk_snapshot_free_to_node(snap);
    if (gShot)
        cairo_surface_destroy(gShot);
    gShot = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    cairo_t* cr = cairo_create(gShot);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_paint(cr);
    if (node)
        {
        gsk_render_node_draw(node, cr);
        gsk_render_node_unref(node);
        }
    cairo_destroy(cr);
    cairo_surface_flush(gShot);
    g_object_unref(p);
    }
/* The window's content as it is on screen, region (x, y, w, h) of the content (below any menu
 * bar), into out as w * h opaque 0xAARRGGBB words.  The TOPLEVEL renders through its paintable --
 * its own background, every widget on it, a GtkGLArea's frame as the texture it composited -- into
 * a cairo surface shifted so the region lands at its origin.  A widget paintable shows the frames
 * rendered since it was made, one behind: so each window keeps one, and each snapshot asks for a
 * frame and waits (bounded) for the frame clock to paint it and one more.  The picture is the window
 * as it is now, at the cost of two frames. */
static GdkPaintable* gSnapP[UXGTK_MAXW];
static int gSnapPainted;
static void snap_after_paint(GdkFrameClock* fc, gpointer ud)
    {
    (void)fc;
    (void)ud;
    gSnapPainted++;
    }
static gboolean snap_give_up(gpointer ud)
    {
    *(int*)ud = 1;
    return G_SOURCE_REMOVE;
    }
int ux_gtk_window_snapshot(int handle, int x, int y, int w, int h, uint32_t* out)
    {
    if (handle <= 0 || handle >= UXGTK_MAXW || !gWin[handle] || !gFix[handle] || w <= 0 || h <= 0 || !out)
        return 0;
    GtkWidget* top = GTK_WIDGET(gWin[handle]);
    if (gtk_widget_get_width(GTK_WIDGET(gFix[handle])) <= 0)
        {
        guint beat = g_timeout_add(5, ux_gtk_heartbeat, NULL);
        for (int spins = 0; gtk_widget_get_width(GTK_WIDGET(gFix[handle])) <= 0 && spins < 120; spins++)
            g_main_context_iteration(NULL, TRUE);
        for (int i = 0; i < 10; i++)
            g_main_context_iteration(NULL, FALSE);
        g_source_remove(beat);
        }
    int tw = gtk_widget_get_width(top), th = gtk_widget_get_height(top);
    graphene_point_t o = GRAPHENE_POINT_INIT(0, 0), at;
    if (tw <= 0 || th <= 0 || !gtk_widget_compute_point(GTK_WIDGET(gFix[handle]), top, &o, &at))
        return 0;
    if (!gSnapP[handle])
        {
        gSnapP[handle] = gtk_widget_paintable_new(top);
        GdkFrameClock* fc = gtk_widget_get_frame_clock(top);
        if (fc)
            g_signal_connect(fc, "after-paint", G_CALLBACK(snap_after_paint), NULL);
        }
    /* a frame, painted now: ask for one and wait for the frame clock to paint it, until the paintable
     * has a picture (a new one needs a frame or two first) or half a second has gone */
    GdkPaintable* p = gSnapP[handle];
    GskRenderNode* node = NULL;
    int late = 0;
    guint beat = g_timeout_add(5, ux_gtk_heartbeat, NULL);
    guint limit = g_timeout_add(500, snap_give_up, &late);
    while (!node && !late)
        {
        /* two paints: the paintable answers with the frame BEFORE the one just painted, so the frame
         * asked for is the paintable's only after the next one */
        int was = gSnapPainted;
        gtk_widget_queue_draw(top);
        while (gSnapPainted < was + 1 && !late)
            g_main_context_iteration(NULL, TRUE);
        gtk_widget_queue_draw(top);
        while (gSnapPainted < was + 2 && !late)
            g_main_context_iteration(NULL, TRUE);
        GtkSnapshot* snap = gtk_snapshot_new();
        gdk_paintable_snapshot(p, GDK_SNAPSHOT(snap), tw, th);
        node = gtk_snapshot_free_to_node(snap);
        }
    if (!late)
        g_source_remove(limit);
    g_source_remove(beat);
    if (!node)
        return 0;
    cairo_surface_t* cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    cairo_t* cr = cairo_create(cs);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_paint(cr);
    cairo_translate(cr, -(at.x + x), -(at.y + y));
    gsk_render_node_draw(node, cr);
    gsk_render_node_unref(node);
    cairo_destroy(cr);
    cairo_surface_flush(cs);
    const unsigned char* d = cairo_image_surface_get_data(cs);
    int stride = cairo_image_surface_get_stride(cs);
    for (int j = 0; j < h; j++)
        {
        const uint32_t* row = (const uint32_t*)(d + j * stride);
        for (int i = 0; i < w; i++)
            out[j * w + i] = 0xFF000000u | (row[i] & 0x00FFFFFFu); /* opaque: painted over white */
        }
    cairo_surface_destroy(cs);
    return 1;
    }
/* ── the modal alert: GtkAlertDialog + a nested main loop ────────────────────
 * choose() is async by design; alertRun's contract is synchronous, so the
 * completion quits a nested GMainLoop — the GTK twin of NSAlert's runModal.
 * The rigs arm ux_gtk_alert_auto first: a timeout that (optionally) renders
 * the OPEN dialog into the shot surface and then cancels the choose, so the
 * gate and the portrait both run headless and deterministic. */
static GMainLoop* gAlertLoop;
static GCancellable* gAlertCancel;
static int gAlertResult; /* 0-based */
static int gAlertAutoMs;
static int gAlertAutoShot;

static void gtkRenderWidgetToShot(GtkWidget* wgt)
    {
    guint beat = g_timeout_add(5, ux_gtk_heartbeat, NULL);
    int spins = 0;
    while (gtk_widget_get_width(wgt) <= 0 && spins < 120)
        {
        g_main_context_iteration(NULL, TRUE);
        spins++;
        }
    int w = gtk_widget_get_width(wgt), h = gtk_widget_get_height(wgt);
    if (w <= 0 || h <= 0)
        {
        g_source_remove(beat);
        return;
        }
    GdkPaintable* p = gtk_widget_paintable_new(wgt);
    gtk_widget_queue_draw(wgt);
    for (int i = 0; i < 30; i++)
        g_main_context_iteration(NULL, TRUE);
    g_source_remove(beat);
    GtkSnapshot* snap = gtk_snapshot_new();
    gdk_paintable_snapshot(p, GDK_SNAPSHOT(snap), w, h);
    GskRenderNode* node = gtk_snapshot_free_to_node(snap);
    if (gShot)
        cairo_surface_destroy(gShot);
    gShot = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    cairo_t* cr = cairo_create(gShot);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_paint(cr);
    if (node)
        {
        gsk_render_node_draw(node, cr);
        gsk_render_node_unref(node);
        }
    cairo_destroy(cr);
    cairo_surface_flush(gShot);
    g_object_unref(p);
    }

static void alert_done(GObject* src, GAsyncResult* res, gpointer ud)
    {
    GError* err = NULL;
    int idx = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(src), res, &err);
    /* cancelled -> the cancel button */
    if (err)
        {
        idx = GPOINTER_TO_INT(ud);
        g_error_free(err);
        }
    gAlertResult = idx;
    if (gAlertLoop)
        g_main_loop_quit(gAlertLoop);
    }
static gboolean alert_auto_cb(gpointer ud)
    {
    if (gAlertAutoShot)
        {
        GListModel* tops = gtk_window_get_toplevels();
        guint n = g_list_model_get_n_items(tops);
        for (guint i = 0; i < n; i++)
            {
            GtkWindow* w = g_list_model_get_item(tops, i);
            int ours = 0;
            for (int k = 0; k < UXGTK_MAXW; k++)
                if (gWin[k] == w)
                    ours = 1;
            if (!ours)
                gtkRenderWidgetToShot(GTK_WIDGET(w)); /* the dialog */
            g_object_unref(w);
            }
        }
    if (gAlertCancel)
        g_cancellable_cancel(gAlertCancel);
    return G_SOURCE_REMOVE;
    }
void ux_gtk_alert_auto(int ms, int shot)
    {
    gAlertAutoMs = ms;
    gAlertAutoShot = shot;
    }

int ux_gtk_alert(int parentHandle, const char* lines, const char* buttons, int defBtn)
    {
    /* first pipe-separated line = message; the rest, newline-joined = detail */
    char** ls = g_strsplit(lines, "|", -1);
    char* detail = (ls[0] && ls[1]) ? g_strjoinv("\n", ls + 1) : NULL;
    char** bs = g_strsplit(buttons, "|", -1);
    int nbtn = 0;
    while (bs[nbtn])
        nbtn++;
    if (nbtn == 0)
        {
        g_strfreev(ls);
        g_strfreev(bs);
        g_free(detail);
        return 1;
        }
    GtkAlertDialog* d = gtk_alert_dialog_new("%s", ls[0] ? ls[0] : "");
    if (detail)
        gtk_alert_dialog_set_detail(d, detail);
    gtk_alert_dialog_set_buttons(d, (const char* const*)bs);
    gtk_alert_dialog_set_default_button(d, defBtn - 1);
    gtk_alert_dialog_set_cancel_button(d, nbtn - 1);
    gtk_alert_dialog_set_modal(d, TRUE);
    GtkWindow* parent = (parentHandle > 0 && parentHandle < UXGTK_MAXW) ? gWin[parentHandle] : NULL;
    gAlertResult = nbtn - 1;
    gAlertCancel = g_cancellable_new();
    if (gAlertAutoMs > 0)
        g_timeout_add(gAlertAutoMs, alert_auto_cb, NULL);
    gAlertLoop = g_main_loop_new(NULL, FALSE);
    gtk_alert_dialog_choose(d, parent, gAlertCancel, alert_done, GINT_TO_POINTER(nbtn - 1));
    g_main_loop_run(gAlertLoop);
    g_main_loop_unref(gAlertLoop);
    gAlertLoop = NULL;
    g_object_unref(gAlertCancel);
    gAlertCancel = NULL;
    g_object_unref(d);
    g_free(detail);
    g_strfreev(ls);
    g_strfreev(bs);
    gAlertAutoMs = 0;
    gAlertAutoShot = 0;
    return gAlertResult + 1; /* the neutral 1-based index */
    }

/* ── the native table: GtkColumnView ─────────────────────────────────────────
 * A UXTableView realized as a real GtkColumnView in a GtkScrolledWindow.  Like AppKit's
 * NSTableView it holds no data of its own: the model is a list of N placeholder items, and each
 * cell's text is pulled from the peer UXTableView through the hooks (the same datasource that
 * feeds the drawn table).  The user's selection goes back through the selectset hook; one the
 * app makes is pushed in with ux_gtk_table_select, muted so it is not echoed back. */
typedef int (*tbl_rows_fn)(void*);
typedef const char* (*tbl_cell_fn)(void*, int, int);
typedef int (*tbl_cols_fn)(void*);
typedef const char* (*tbl_title_fn)(void*, int);
typedef int (*tbl_width_fn)(void*, int);
typedef int (*tbl_multi_fn)(void*);
typedef void (*tbl_selset_fn)(void*, int*, int);
static tbl_rows_fn gTblRows;
static tbl_cell_fn gTblCell;
static tbl_cols_fn gTblCols;
static tbl_title_fn gTblTitle;
static tbl_width_fn gTblWidth;
static tbl_multi_fn gTblMulti;
static tbl_selset_fn gTblSelSet;
static int gTblMute;
void ux_gtk_set_table_hooks(void* rows, void* cell, void* cols, void* title, void* width, void* multi, void* selset)
    {
    gTblRows = (tbl_rows_fn)rows;
    gTblCell = (tbl_cell_fn)cell;
    gTblCols = (tbl_cols_fn)cols;
    gTblTitle = (tbl_title_fn)title;
    gTblWidth = (tbl_width_fn)width;
    gTblMulti = (tbl_multi_fn)multi;
    gTblSelSet = (tbl_selset_fn)selset;
    }
/* A table row dragged out: its first column, if the table drags its rows. */
static GdkContentProvider* tbl_drag_prepare(GtkDragSource* src, double x, double y, gpointer li)
    {
    (void)x; (void)y;
    GtkWidget* w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(src));
    GtkWidget* cv = g_object_get_data(G_OBJECT(w), "ux-cv");
    void* peer = cv ? g_object_get_data(G_OBJECT(cv), "ux-peer") : NULL;
    if (!peer || !gTblDrags || !gTblDrags(peer) || !gTblCell)
        return NULL;
    const char* t = gTblCell(peer, (int)gtk_list_item_get_position(GTK_LIST_ITEM(li)), 0);
    return row_content(t ? t : "");
    }
static void row_drag_begin(GtkDragSource* src, GdkDrag* drag, gpointer ud)
    {
    (void)drag; (void)ud;
    GtkWidget* w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(src));
    GdkPaintable* p = gtk_widget_paintable_new(w);
    gtk_drag_source_set_icon(src, p, 0, 0);
    g_object_unref(p);
    }
static void tbl_setup(GtkSignalListItemFactory* f, GtkListItem* item, gpointer ud)
    {
    (void)ud;
    GtkWidget* l = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(l), 0.0f);
    gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
    gtk_list_item_set_child(item, l);
    g_object_set_data(G_OBJECT(l), "ux-cv", g_object_get_data(G_OBJECT(f), "ux-view"));
    GtkDragSource* ds = gtk_drag_source_new();
    gtk_drag_source_set_actions(ds, GDK_ACTION_COPY);
    g_signal_connect(ds, "prepare", G_CALLBACK(tbl_drag_prepare), item);
    g_signal_connect(ds, "drag-begin", G_CALLBACK(row_drag_begin), NULL);
    gtk_widget_add_controller(l, GTK_EVENT_CONTROLLER(ds));
    }
static void tbl_bind(GtkSignalListItemFactory* f, GtkListItem* item, gpointer col)
    {
    GtkWidget* cv = g_object_get_data(G_OBJECT(f), "ux-view");
    void* peer = cv ? g_object_get_data(G_OBJECT(cv), "ux-peer") : NULL;
    const char* t = (peer && gTblCell) ? gTblCell(peer, (int)gtk_list_item_get_position(item), GPOINTER_TO_INT(col)) : "";
    gtk_label_set_text(GTK_LABEL(gtk_list_item_get_child(item)), t ? t : "");
    }
static void tbl_sel_changed(GtkSelectionModel* m, guint pos, guint n, gpointer cv)
    {
    (void)pos; (void)n;
    if (gTblMute || !gTblSelSet)
        return;
    void* peer = g_object_get_data(G_OBJECT(cv), "ux-peer");
    GtkBitset* bs = gtk_selection_model_get_selection(m);
    guint64 cnt = gtk_bitset_get_size(bs);
    int* rows = g_new0(int, cnt > 0 ? cnt : 1);
    int k = 0;
    GtkBitsetIter it;
    guint v;
    for (gboolean ok = gtk_bitset_iter_init_first(&it, bs, &v); ok; ok = gtk_bitset_iter_next(&it, &v))
        rows[k++] = (int)v;
    gtk_bitset_unref(bs);
    gTblSelSet(peer, rows, k);
    g_free(rows);
    }
static GtkColumnView* tbl_view(int handle, int node)
    {
    GtkWidget* sw = gCtl[handle][node];
    return sw ? GTK_COLUMN_VIEW(g_object_get_data(G_OBJECT(sw), "ux-view")) : NULL;
    }
void ux_gtk_table_reload(int handle, int node)
    {
    GtkColumnView* cv = tbl_view(handle, node);
    if (!cv)
        return;
    void* peer = g_object_get_data(G_OBJECT(cv), "ux-peer");
    GListStore* store = g_object_get_data(G_OBJECT(cv), "ux-store");
    int n = gTblRows ? gTblRows(peer) : 0;
    guint have = g_list_model_get_n_items(G_LIST_MODEL(store));
    /* replace every row: a changed count and changed text both rebind */
    GObject** items = g_new0(GObject*, n > 0 ? n : 1);
    for (int i = 0; i < n; i++)
        items[i] = G_OBJECT(gtk_string_object_new(""));
    gTblMute++;
    g_list_store_splice(store, 0, have, (gpointer*)items, (guint)n);
    gTblMute--;
    for (int i = 0; i < n; i++)
        g_object_unref(items[i]);
    g_free(items);
    }
/* A column view whose columns all have empty titles shows no header row.  GTK has no switch for
   it; the header is the view's child named "header". */
static void hide_untitled_header(GtkWidget* cv, void* peer, int ncols)
    {
    for (int c = 0; c < ncols; c++)
        {
        const char* ti = gTblTitle ? gTblTitle(peer, c) : "";
        if (ti && ti[0])
            return;
        }
    for (GtkWidget* k = gtk_widget_get_first_child(cv); k; k = gtk_widget_get_next_sibling(k))
        if (strcmp(gtk_widget_get_css_name(k), "header") == 0)
            gtk_widget_set_visible(k, FALSE);
    }
void ux_gtk_make_table(int handle, int node, int x, int y, int w, int h, void* peer)
    {
    GListStore* store = g_list_store_new(GTK_TYPE_STRING_OBJECT);
    int multi = gTblMulti ? gTblMulti(peer) : 0;
    GtkSelectionModel* sel;
    if (multi)
        sel = GTK_SELECTION_MODEL(gtk_multi_selection_new(G_LIST_MODEL(store)));
    else
        {
        GtkSingleSelection* ss = gtk_single_selection_new(G_LIST_MODEL(store));
        gtk_single_selection_set_autoselect(ss, FALSE);
        gtk_single_selection_set_can_unselect(ss, TRUE);
        sel = GTK_SELECTION_MODEL(ss);
        }
    GtkWidget* cv = gtk_column_view_new(sel);
    gtk_column_view_set_show_row_separators(GTK_COLUMN_VIEW(cv), FALSE);
    g_object_set_data(G_OBJECT(cv), "ux-peer", peer);
    g_object_set_data(G_OBJECT(cv), "ux-store", store);
    int ncols = gTblCols ? gTblCols(peer) : 1;
    for (int c = 0; c < ncols; c++)
        {
        GtkListItemFactory* f = gtk_signal_list_item_factory_new();
        g_object_set_data(G_OBJECT(f), "ux-view", cv);
        g_signal_connect(f, "setup", G_CALLBACK(tbl_setup), NULL);
        g_signal_connect(f, "bind", G_CALLBACK(tbl_bind), GINT_TO_POINTER(c));
        GtkColumnViewColumn* col = gtk_column_view_column_new(gTblTitle ? gTblTitle(peer, c) : "", f);
        int cw = gTblWidth ? gTblWidth(peer, c) : 80;
        if (cw > 0)
            gtk_column_view_column_set_fixed_width(col, cw);
        gtk_column_view_column_set_resizable(col, TRUE);
        if (c == ncols - 1)
            gtk_column_view_column_set_expand(col, TRUE);
        gtk_column_view_append_column(GTK_COLUMN_VIEW(cv), col);
        g_object_unref(col);
        }
    g_signal_connect(sel, "selection-changed", G_CALLBACK(tbl_sel_changed), cv);
    hide_untitled_header(cv, peer, ncols);
    GtkWidget* sw = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sw), cv);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sw), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC);
    g_object_set_data(G_OBJECT(sw), "ux-view", cv);
    park(handle, node, sw, x, y, w, h);
    ux_gtk_table_reload(handle, node);
    }
/* The app's selection, pushed into the view (muted: it is not the user's, so not echoed back). */
void ux_gtk_table_select(int handle, int node, int* rows, int n)
    {
    GtkColumnView* cv = tbl_view(handle, node);
    if (!cv)
        return;
    GtkSelectionModel* m = gtk_column_view_get_model(cv);
    gTblMute++;
    gtk_selection_model_unselect_all(m);
    for (int i = 0; i < n; i++)
        gtk_selection_model_select_item(m, (guint)rows[i], FALSE);
    gTblMute--;
    }
/* Tests: the view's row count, a bound cell's text, and a USER's selection of a row. */
int ux_gtk_test_table_rows(int handle, int node)
    {
    GtkColumnView* cv = tbl_view(handle, node);
    return cv ? (int)g_list_model_get_n_items(G_LIST_MODEL(gtk_column_view_get_model(cv))) : -1;
    }
int ux_gtk_test_table_selected(int handle, int node, int row)
    {
    GtkColumnView* cv = tbl_view(handle, node);
    return cv ? gtk_selection_model_is_selected(gtk_column_view_get_model(cv), (guint)row) : -1;
    }
void ux_gtk_test_table_user_select(int handle, int node, int row)
    {
    GtkColumnView* cv = tbl_view(handle, node);
    if (cv)
        gtk_selection_model_select_item(gtk_column_view_get_model(cv), (guint)row, TRUE); /* as a click does */
    }
/* The text the view's cells show for (row, col): what the bind handler would put there. */
int ux_gtk_test_table_cell_is(int handle, int node, int row, int col, const char* want)
    {
    GtkColumnView* cv = tbl_view(handle, node);
    void* peer = cv ? g_object_get_data(G_OBJECT(cv), "ux-peer") : NULL;
    const char* t = (peer && gTblCell) ? gTblCell(peer, row, col) : NULL;
    return t && strcmp(t, want) == 0;
    }
int ux_gtk_test_table_title_is(int handle, int node, int col, const char* want)
    {
    GtkColumnView* cv = tbl_view(handle, node);
    if (!cv)
        return 0;
    GListModel* cols = gtk_column_view_get_columns(cv);
    GtkColumnViewColumn* c = g_list_model_get_item(cols, (guint)col);
    if (!c)
        return 0;
    int same = strcmp(gtk_column_view_column_get_title(c) ? gtk_column_view_column_get_title(c) : "", want) == 0;
    g_object_unref(c);
    return same;
    }

/* ── the native outline: GtkColumnView over a GtkTreeListModel ─────────────────
 * A UXOutlineView realized as a tree: a GtkTreeListModel whose children are asked for on demand
 * through the outline hooks (the outline's own datasource, as NSOutlineView does), with a
 * GtkTreeExpander in the first column.  An expansion the user makes is reported back
 * (nativeDidExpand), which re-flattens the outline's rows into the native visible order, so the
 * selection is reported by row exactly as a table's is.  Each item is a plain GObject carrying the
 * app's own item pointer. */
typedef int (*ol_children_fn)(void*, void*);
typedef void* (*ol_child_fn)(void*, void*, int);
typedef int (*ol_expandable_fn)(void*, void*);
typedef const char* (*ol_value_fn)(void*, void*, int);
typedef void (*ol_didexpand_fn)(void*, void*, int);
typedef int (*ol_isexpanded_fn)(void*, void*);
static ol_children_fn gOlChildren;
static ol_child_fn gOlChild;
static ol_expandable_fn gOlExpandable;
static ol_value_fn gOlValue;
static ol_didexpand_fn gOlDidExpand;
static ol_isexpanded_fn gOlIsExpanded;
void ux_gtk_set_outline_hooks(void* children, void* child, void* expandable, void* value, void* didexpand, void* isexpanded)
    {
    gOlChildren = (ol_children_fn)children;
    gOlChild = (ol_child_fn)child;
    gOlExpandable = (ol_expandable_fn)expandable;
    gOlValue = (ol_value_fn)value;
    gOlDidExpand = (ol_didexpand_fn)didexpand;
    gOlIsExpanded = (ol_isexpanded_fn)isexpanded;
    }
static GListStore* ol_children_store(void* peer, void* item)
    {
    GListStore* st = g_list_store_new(G_TYPE_OBJECT);
    int n = gOlChildren ? gOlChildren(peer, item) : 0;
    for (int i = 0; i < n; i++)
        {
        GObject* o = g_object_new(G_TYPE_OBJECT, NULL);
        g_object_set_data(o, "ux-item", gOlChild ? gOlChild(peer, item, i) : NULL);
        g_list_store_append(st, o);
        g_object_unref(o);
        }
    return st;
    }
static GListModel* ol_create(gpointer obj, gpointer peer)
    {
    void* item = g_object_get_data(G_OBJECT(obj), "ux-item");
    if (!gOlExpandable || !gOlExpandable(peer, item))
        return NULL;
    return G_LIST_MODEL(ol_children_store(peer, item));
    }
static void ol_row_expanded(GtkTreeListRow* row, GParamSpec* ps, gpointer peer)
    {
    (void)ps;
    if (gTblMute || !gOlDidExpand)
        return;
    GObject* o = gtk_tree_list_row_get_item(row);
    gOlDidExpand(peer, g_object_get_data(o, "ux-item"), gtk_tree_list_row_get_expanded(row) ? 1 : 0);
    g_object_unref(o);
    }
/* An outline row: what it carries dragged out (the app says; NULL, it does not drag), on either
   button, since a secondary-button drag is how a connection is drawn from a row.  Its drag reports
   where it began and where it ends, so a line can follow it. */
static GdkContentProvider* ol_drag_prepare(GtkDragSource* src, double x, double y, gpointer ud)
    {
    (void)ud;
    GtkWidget* w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(src));
    GtkWidget* cv = g_object_get_data(G_OBJECT(w), "ux-cv");
    void* peer = cv ? g_object_get_data(G_OBJECT(cv), "ux-peer") : NULL;
    void* item = g_object_get_data(G_OBJECT(w), "ux-olitem");
    const char* t = (peer && item && gOlDragText) ? gOlDragText(peer, item, 0) : NULL;
    if (!t)
        return NULL;
    int handle = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(cv), "ux-handle"));
    g_object_set_data_full(G_OBJECT(src), "ux-text", g_strdup(t), g_free);
    if (gItemHover)
        {
        int px, py;
        content_point(w, handle, x, y, &px, &py);
        gItemHover(t, handle, px, py);
        }
    return row_content(t);
    }
static void ol_drag_end(GtkDragSource* src, GdkDrag* drag, gboolean del, gpointer ud)
    {
    (void)drag; (void)del; (void)ud;
    GtkWidget* w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(src));
    GtkWidget* cv = g_object_get_data(G_OBJECT(w), "ux-cv");
    const char* t = g_object_get_data(G_OBJECT(src), "ux-text");
    if (t && gItemHover && cv)
        gItemHover(t, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(cv), "ux-handle")), -1, -1);
    }
/* A row dragged onto an outline row: a drop at that row's point, in the window's terms. */
static GdkDragAction ol_drop_motion(GtkDropTarget* dt, double x, double y, gpointer ud)
    {
    (void)ud;
    const GValue* v = gtk_drop_target_get_value(dt);
    const char* t = v && G_VALUE_HOLDS_STRING(v) ? row_text(g_value_get_string(v)) : NULL;
    GtkWidget* w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(dt));
    GtkWidget* cv = g_object_get_data(G_OBJECT(w), "ux-cv");
    if (t && gItemHover && cv)
        {
        int handle = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(cv), "ux-handle"));
        int px, py;
        content_point(w, handle, x, y, &px, &py);
        gItemHover(t, handle, px, py);
        }
    return t || !v ? GDK_ACTION_COPY : 0;
    }
static gboolean ol_drop(GtkDropTarget* dt, const GValue* v, double x, double y, gpointer ud)
    {
    (void)dt; (void)ud;
    const char* t = G_VALUE_HOLDS_STRING(v) ? row_text(g_value_get_string(v)) : NULL;
    GtkWidget* w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(dt));
    GtkWidget* cv = g_object_get_data(G_OBJECT(w), "ux-cv");
    if (!t || !gItemDrop || !cv)
        return FALSE;
    int handle = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(cv), "ux-handle"));
    int px, py;
    content_point(w, handle, x, y, &px, &py);
    char* copy = g_strdup(t);
    if (gItemHover)
        gItemHover(copy, handle, -1, -1);
    gItemDrop(copy, handle, px, py);
    g_free(copy);
    return TRUE;
    }
static void ol_setup(GtkSignalListItemFactory* f, GtkListItem* li, gpointer col)
    {
    GtkWidget* l = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(l), 0.0f);
    gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
    GtkWidget* cell = l;
    if (GPOINTER_TO_INT(col) == 0)
        {
        GtkWidget* ex = gtk_tree_expander_new();
        gtk_tree_expander_set_child(GTK_TREE_EXPANDER(ex), l);
        gtk_list_item_set_child(li, ex);
        cell = ex;
        }
    else
        gtk_list_item_set_child(li, l);
    g_object_set_data(G_OBJECT(cell), "ux-cv", g_object_get_data(G_OBJECT(f), "ux-view"));
    GtkDragSource* ds = gtk_drag_source_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(ds), 0); /* either button */
    gtk_drag_source_set_actions(ds, GDK_ACTION_COPY);
    g_signal_connect(ds, "prepare", G_CALLBACK(ol_drag_prepare), NULL);
    g_signal_connect(ds, "drag-begin", G_CALLBACK(row_drag_begin), NULL);
    g_signal_connect(ds, "drag-end", G_CALLBACK(ol_drag_end), NULL);
    gtk_widget_add_controller(cell, GTK_EVENT_CONTROLLER(ds));
    GtkDropTarget* dt = gtk_drop_target_new(G_TYPE_STRING, GDK_ACTION_COPY);
    gtk_drop_target_set_preload(dt, TRUE);
    g_signal_connect(dt, "motion", G_CALLBACK(ol_drop_motion), NULL);
    g_signal_connect(dt, "enter", G_CALLBACK(ol_drop_motion), NULL);
    g_signal_connect(dt, "drop", G_CALLBACK(ol_drop), NULL);
    gtk_widget_add_controller(cell, GTK_EVENT_CONTROLLER(dt));
    }
static void ol_bind(GtkSignalListItemFactory* f, GtkListItem* li, gpointer col)
    {
    GtkWidget* cv = g_object_get_data(G_OBJECT(f), "ux-view");
    void* peer = g_object_get_data(G_OBJECT(cv), "ux-peer");
    GtkTreeListRow* row = GTK_TREE_LIST_ROW(gtk_list_item_get_item(li));
    GObject* o = gtk_tree_list_row_get_item(row);
    void* item = g_object_get_data(o, "ux-item");
    g_object_unref(o);
    GtkWidget* child = gtk_list_item_get_child(li);
    GtkWidget* label = child;
    g_object_set_data(G_OBJECT(child), "ux-olitem", item);
    if (GPOINTER_TO_INT(col) == 0)
        {
        gtk_tree_expander_set_list_row(GTK_TREE_EXPANDER(child), row);
        label = gtk_tree_expander_get_child(GTK_TREE_EXPANDER(child));
        /* (Expansion is NOT applied here: bind runs inside the list's layout, and opening a row
         * inserts rows mid-measure -- GTK crashes on it.  ol_apply_expansion does it after a reload.) */
        if (!g_object_get_data(G_OBJECT(row), "ux-watched"))
            {
            g_object_set_data(G_OBJECT(row), "ux-watched", GINT_TO_POINTER(1));
            g_signal_connect(row, "notify::expanded", G_CALLBACK(ol_row_expanded), peer);
            }
        }
    const char* t = gOlValue ? gOlValue(peer, item, GPOINTER_TO_INT(col)) : "";
    gtk_label_set_text(GTK_LABEL(label), t ? t : "");
    }
/* The model's expansion, shown: walk the visible rows and open each item the outline has open.
 * Opening one inserts its children right after it, so the same walk reaches them in turn. */
static void ol_apply_expansion(GtkColumnView* cv, void* peer)
    {
    GListModel* m = G_LIST_MODEL(gtk_column_view_get_model(cv));
    gTblMute++;
    for (guint i = 0; i < g_list_model_get_n_items(m); i++)
        {
        GtkTreeListRow* row = g_list_model_get_item(m, i);
        if (!row)
            continue;
        GObject* o = gtk_tree_list_row_get_item(row);
        void* item = g_object_get_data(o, "ux-item");
        g_object_unref(o);
        if (gOlIsExpanded && gOlIsExpanded(peer, item) && gtk_tree_list_row_is_expandable(row)
            && !gtk_tree_list_row_get_expanded(row))
            gtk_tree_list_row_set_expanded(row, TRUE);
        g_object_unref(row);
        }
    gTblMute--;
    }
void ux_gtk_outline_reload(int handle, int node)
    {
    GtkColumnView* cv = tbl_view(handle, node);
    if (!cv)
        return;
    void* peer = g_object_get_data(G_OBJECT(cv), "ux-peer");
    GListStore* root = g_object_get_data(G_OBJECT(cv), "ux-store");
    GListStore* fresh = ol_children_store(peer, NULL);
    guint n = g_list_model_get_n_items(G_LIST_MODEL(fresh));
    GObject** items = g_new0(GObject*, n > 0 ? n : 1);
    for (guint i = 0; i < n; i++)
        items[i] = g_list_model_get_item(G_LIST_MODEL(fresh), i);
    gTblMute++;
    g_list_store_splice(root, 0, g_list_model_get_n_items(G_LIST_MODEL(root)), (gpointer*)items, n);
    gTblMute--;
    for (guint i = 0; i < n; i++)
        g_object_unref(items[i]);
    g_free(items);
    g_object_unref(fresh);
    ol_apply_expansion(cv, peer);
    }
void ux_gtk_make_outline(int handle, int node, int x, int y, int w, int h, void* peer)
    {
    GListStore* root = g_list_store_new(G_TYPE_OBJECT);
    GtkTreeListModel* tree = gtk_tree_list_model_new(G_LIST_MODEL(root), FALSE, FALSE, ol_create, peer, NULL);
    int multi = gTblMulti ? gTblMulti(peer) : 0;
    GtkSelectionModel* sel;
    if (multi)
        sel = GTK_SELECTION_MODEL(gtk_multi_selection_new(G_LIST_MODEL(tree)));
    else
        {
        GtkSingleSelection* ss = gtk_single_selection_new(G_LIST_MODEL(tree));
        gtk_single_selection_set_autoselect(ss, FALSE);
        gtk_single_selection_set_can_unselect(ss, TRUE);
        sel = GTK_SELECTION_MODEL(ss);
        }
    GtkWidget* cv = gtk_column_view_new(sel);
    gtk_column_view_set_show_row_separators(GTK_COLUMN_VIEW(cv), FALSE);
    g_object_set_data(G_OBJECT(cv), "ux-peer", peer);
    g_object_set_data(G_OBJECT(cv), "ux-store", root);
    g_object_set_data(G_OBJECT(cv), "ux-handle", GINT_TO_POINTER(handle));
    int ncols = gTblCols ? gTblCols(peer) : 1;
    if (ncols < 1)
        ncols = 1;
    for (int c = 0; c < ncols; c++)
        {
        GtkListItemFactory* f = gtk_signal_list_item_factory_new();
        g_object_set_data(G_OBJECT(f), "ux-view", cv);
        g_signal_connect(f, "setup", G_CALLBACK(ol_setup), GINT_TO_POINTER(c));
        g_signal_connect(f, "bind", G_CALLBACK(ol_bind), GINT_TO_POINTER(c));
        GtkColumnViewColumn* col = gtk_column_view_column_new(gTblTitle ? gTblTitle(peer, c) : "", f);
        int cw = gTblWidth ? gTblWidth(peer, c) : 120;
        if (cw > 0)
            gtk_column_view_column_set_fixed_width(col, cw);
        gtk_column_view_column_set_resizable(col, TRUE);
        if (c == ncols - 1)
            gtk_column_view_column_set_expand(col, TRUE);
        gtk_column_view_append_column(GTK_COLUMN_VIEW(cv), col);
        g_object_unref(col);
        }
    g_signal_connect(sel, "selection-changed", G_CALLBACK(tbl_sel_changed), cv);
    hide_untitled_header(cv, peer, ncols);
    GtkWidget* sw = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sw), cv);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sw), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC);
    g_object_set_data(G_OBJECT(sw), "ux-view", cv);
    park(handle, node, sw, x, y, w, h);
    ux_gtk_outline_reload(handle, node);
    }
/* Tests: a USER expanding or collapsing the row at a visible position (the expander's own call). */
void ux_gtk_test_outline_expand(int handle, int node, int row, int on)
    {
    GtkColumnView* cv = tbl_view(handle, node);
    if (!cv)
        return;
    GListModel* m = G_LIST_MODEL(gtk_column_view_get_model(cv));
    GtkTreeListRow* r = g_list_model_get_item(m, (guint)row);
    if (r)
        {
        gtk_tree_list_row_set_expanded(r, on != 0);
        g_object_unref(r);
        }
    }

/* ── the native panels: file open / save, colour, font (GTK 4.10+'s dialogs) ──
 * Each is asynchronous in GTK 4; the seam is synchronous (the toolkit's file panel, alerts and
 * pickers all are), so each runs the alert's shape: start it, spin a nested main loop until its
 * finish callback, return.  Cancel (or an error) answers 0.
 *
 * Tests answer them unattended: ux_gtk_dialog_auto(ms, ...) arms a timer that finds the dialog
 * among the toplevels -- with GDK_DEBUG=no-portals the file dialog runs in-process as a
 * GtkFileChooserDialog, and the colour and font dialogs always do -- sets the given file, colour
 * or font on it and presses its OK, so the whole round trip through the real dialog is checked. */
static GMainLoop* gDlgLoop;
static int gDlgOk;
static char* gDlgPath;
static GdkRGBA gDlgRGBA;
static PangoFontDescription* gDlgFont;
static int gDlgAutoMs;
static char gDlgAutoPath[1024];
static GdkRGBA gDlgAutoRGBA;
static char gDlgAutoFont[256];
static int gDlgAutoCancel;
static int gDlgAutoSeen;
void ux_gtk_dialog_auto(int ms, const char* path, int r, int g, int b, const char* font, int cancel)
    {
    gDlgAutoMs = ms;
    g_strlcpy(gDlgAutoPath, path ? path : "", sizeof gDlgAutoPath);
    gDlgAutoRGBA = (GdkRGBA){ r / 255.0f, g / 255.0f, b / 255.0f, 1.0f };
    g_strlcpy(gDlgAutoFont, font ? font : "", sizeof gDlgAutoFont);
    gDlgAutoCancel = cancel;
    gDlgAutoSeen = 0;
    }
int ux_gtk_dialog_auto_seen(void) { return gDlgAutoSeen; }
G_GNUC_BEGIN_IGNORE_DEPRECATIONS
static gboolean dlg_auto_cb(gpointer unused)
    {
    (void)unused;
    GListModel* tl = gtk_window_get_toplevels();
    for (guint i = 0; i < g_list_model_get_n_items(tl); i++)
        {
        GtkWindow* w = g_list_model_get_item(tl, i);
        int handled = 0;
        if (!GTK_IS_DIALOG(w))
            {
            g_object_unref(w);
            continue; /* the app's own windows */
            }
        if (GTK_IS_FILE_CHOOSER(w))
            {
            gDlgAutoSeen = 1;
            if (!gDlgAutoCancel)
                {
                GFile* f = g_file_new_for_path(gDlgAutoPath);
                if (gtk_file_chooser_get_action(GTK_FILE_CHOOSER(w)) == GTK_FILE_CHOOSER_ACTION_SAVE)
                    {
                    GFile* dir = g_file_get_parent(f);
                    char* base = g_file_get_basename(f);
                    gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(w), dir, NULL);
                    gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(w), base);
                    g_free(base);
                    g_object_unref(dir);
                    }
                else
                    gtk_file_chooser_set_file(GTK_FILE_CHOOSER(w), f, NULL);
                g_object_unref(f);
                }
            handled = 1;
            }
        else if (GTK_IS_COLOR_CHOOSER(w))
            {
            gDlgAutoSeen = 1;
            if (!gDlgAutoCancel)
                gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(w), &gDlgAutoRGBA);
            handled = 1;
            }
        else if (GTK_IS_FONT_CHOOSER(w))
            {
            gDlgAutoSeen = 1;
            if (!gDlgAutoCancel)
                gtk_font_chooser_set_font(GTK_FONT_CHOOSER(w), gDlgAutoFont);
            handled = 1;
            }
        /* ONE response: a file chooser's OK is ACCEPT, the colour and font dialogs' is OK */
        if (handled && GTK_IS_DIALOG(w))
            gtk_dialog_response(GTK_DIALOG(w), gDlgAutoCancel ? GTK_RESPONSE_CANCEL
                                               : GTK_IS_FILE_CHOOSER(w) ? GTK_RESPONSE_ACCEPT : GTK_RESPONSE_OK);
        g_object_unref(w);
        if (handled)
            return G_SOURCE_REMOVE;
        }
    return G_SOURCE_CONTINUE; /* not up yet: look again */
    }
G_GNUC_END_IGNORE_DEPRECATIONS
static void dlg_arm(void)
    {
    if (gDlgAutoMs > 0)
        g_timeout_add(gDlgAutoMs, dlg_auto_cb, NULL);
    gDlgAutoMs = 0;
    }
static void dlg_run(void)
    {
    gDlgLoop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(gDlgLoop);
    g_main_loop_unref(gDlgLoop);
    gDlgLoop = NULL;
    }
static void dlg_end(void) { if (gDlgLoop) g_main_loop_quit(gDlgLoop); }
static GtkWindow* dlg_parent(void)
    {
    for (int h = 1; h < UXGTK_MAXW; h++)
        if (gWin[h])
            return gWin[h];
    return NULL;
    }
static void file_done(GObject* src, GAsyncResult* res, gpointer save)
    {
    GError* err = NULL;
    GFile* f = save ? gtk_file_dialog_save_finish(GTK_FILE_DIALOG(src), res, &err)
                    : gtk_file_dialog_open_finish(GTK_FILE_DIALOG(src), res, &err);
    if (f)
        {
        gDlgPath = g_file_get_path(f);
        gDlgOk = gDlgPath != NULL;
        g_object_unref(f);
        }
    if (err)
        g_error_free(err);
    dlg_end();
    }
static int file_dialog(const char* prompt, const char* startDir, const char* defName, char* out, int cap, int save)
    {
    GtkFileDialog* d = gtk_file_dialog_new();
    if (prompt && *prompt)
        gtk_file_dialog_set_title(d, prompt);
    gtk_file_dialog_set_modal(d, TRUE);
    if (startDir && *startDir)
        {
        GFile* dir = g_file_new_for_path(startDir);
        gtk_file_dialog_set_initial_folder(d, dir);
        g_object_unref(dir);
        }
    if (save && defName && *defName)
        gtk_file_dialog_set_initial_name(d, defName);
    gDlgOk = 0;
    gDlgPath = NULL;
    dlg_arm();
    if (save)
        gtk_file_dialog_save(d, dlg_parent(), NULL, file_done, GINT_TO_POINTER(1));
    else
        gtk_file_dialog_open(d, dlg_parent(), NULL, file_done, NULL);
    dlg_run();
    g_object_unref(d);
    int ok = 0;
    if (gDlgOk && gDlgPath && cap > 0)
        {
        g_strlcpy(out, gDlgPath, cap);
        ok = 1;
        }
    g_free(gDlgPath);
    gDlgPath = NULL;
    return ok;
    }
int ux_gtk_file_open(const char* prompt, const char* startDir, char* out, int cap)
    {
    return file_dialog(prompt, startDir, NULL, out, cap, 0);
    }
int ux_gtk_file_save(const char* prompt, const char* startDir, const char* defName, char* out, int cap)
    {
    return file_dialog(prompt, startDir, defName, out, cap, 1);
    }
static void color_done(GObject* src, GAsyncResult* res, gpointer unused)
    {
    (void)unused;
    GError* err = NULL;
    GdkRGBA* c = gtk_color_dialog_choose_rgba_finish(GTK_COLOR_DIALOG(src), res, &err);
    if (c)
        {
        gDlgRGBA = *c;
        gDlgOk = 1;
        gdk_rgba_free(c);
        }
    if (err)
        g_error_free(err);
    dlg_end();
    }
int ux_gtk_pick_color(int r, int g, int b, int* outR, int* outG, int* outB)
    {
    GtkColorDialog* d = gtk_color_dialog_new();
    gtk_color_dialog_set_modal(d, TRUE);
    gtk_color_dialog_set_with_alpha(d, FALSE);
    GdkRGBA init = { r / 255.0f, g / 255.0f, b / 255.0f, 1.0f };
    gDlgOk = 0;
    dlg_arm();
    gtk_color_dialog_choose_rgba(d, dlg_parent(), &init, NULL, color_done, NULL);
    dlg_run();
    g_object_unref(d);
    if (!gDlgOk)
        return 0;
    *outR = (int)(gDlgRGBA.red * 255.0f + 0.5f);
    *outG = (int)(gDlgRGBA.green * 255.0f + 0.5f);
    *outB = (int)(gDlgRGBA.blue * 255.0f + 0.5f);
    return 1;
    }
static void font_done(GObject* src, GAsyncResult* res, gpointer unused)
    {
    (void)unused;
    GError* err = NULL;
    PangoFontDescription* fd = gtk_font_dialog_choose_font_finish(GTK_FONT_DIALOG(src), res, &err);
    if (fd)
        {
        gDlgFont = fd;
        gDlgOk = 1;
        }
    if (err)
        g_error_free(err);
    dlg_end();
    }
int ux_gtk_pick_font(const char* inFamily, int inSize, int inBold, int inItalic,
                     char* outFamily, int cap, int* outSize, int* outBold, int* outItalic)
    {
    GtkFontDialog* d = gtk_font_dialog_new();
    gtk_font_dialog_set_modal(d, TRUE);
    PangoFontDescription* init = pango_font_description_new();
    pango_font_description_set_family(init, inFamily && *inFamily ? inFamily : "Sans");
    pango_font_description_set_size(init, (inSize > 0 ? inSize : 13) * PANGO_SCALE);
    pango_font_description_set_weight(init, inBold ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
    pango_font_description_set_style(init, inItalic ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
    gDlgOk = 0;
    gDlgFont = NULL;
    dlg_arm();
    gtk_font_dialog_choose_font(d, dlg_parent(), init, NULL, font_done, NULL);
    dlg_run();
    pango_font_description_free(init);
    g_object_unref(d);
    if (!gDlgOk || !gDlgFont)
        return 0;
    const char* fam = pango_font_description_get_family(gDlgFont);
    g_strlcpy(outFamily, fam ? fam : "", cap);
    int sz = pango_font_description_get_size(gDlgFont);
    *outSize = sz > 0 ? (sz + PANGO_SCALE / 2) / PANGO_SCALE : inSize;
    *outBold = pango_font_description_get_weight(gDlgFont) >= PANGO_WEIGHT_BOLD;
    *outItalic = pango_font_description_get_style(gDlgFont) != PANGO_STYLE_NORMAL;
    pango_font_description_free(gDlgFont);
    gDlgFont = NULL;
    return 1;
    }

/* dump the last shot as a P6 PPM (the capture pipeline's sheet) */
int ux_gtk_dump_ppm(const char* path)
    {
    if (!gShot)
        return 0;
    int w = cairo_image_surface_get_width(gShot), h = cairo_image_surface_get_height(gShot);
    int stride = cairo_image_surface_get_stride(gShot);
    unsigned char* d = cairo_image_surface_get_data(gShot);
    FILE* f = fopen(path, "wb");
    if (!f)
        return 0;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int y = 0; y < h; y++)
        {
        unsigned* row = (unsigned*)(d + y * stride);
        for (int x = 0; x < w; x++)
            {
            unsigned p = row[x];
            unsigned char rgb[3] = {(p >> 16) & 255, (p >> 8) & 255, p & 255};
            fwrite(rgb, 1, 3, f);
            }
        }
    fclose(f);
    return 1;
    }
/* Test rig: spin the frame clock until the window's fixed has an allocation.
 * A headless gate has no window manager driving frames, and a GtkGLArea is
 * realized -- and so can make a context -- only once the widget tree is mapped
 * AND laid out.  The fixed's own width comes from the window; its CHILDREN are
 * allocated during a paint, so one draw is queued and the clock ticked for it
 * (the same shape as ux_gtk_render_scene), which also runs the cairo content
 * callback so a GL view with no context paints its drawRect fallback. */
void ux_gtk_wait_allocated(int handle)
    {
    if (!gWin[handle] || !gFix[handle])
        return;
    guint beat = g_timeout_add(5, ux_gtk_heartbeat, NULL);
    int spins = 0;
    while (gtk_widget_get_width(GTK_WIDGET(gFix[handle])) <= 0 && spins < 120)
        {
        g_main_context_iteration(NULL, TRUE);
        spins++;
        }
    gtk_widget_queue_draw(GTK_WIDGET(gFix[handle]));
    for (int i = 0; i < 30; i++)
        g_main_context_iteration(NULL, TRUE);
    g_source_remove(beat);
    }
int ux_gtk_pixel(int x, int y)
    {
    if (!gShot)        return -1;
    int w = cairo_image_surface_get_width(gShot), h = cairo_image_surface_get_height(gShot);
    if (x < 0 || y < 0 || x >= w || y >= h)
        return -1;
    unsigned char* d = cairo_image_surface_get_data(gShot);
    unsigned* px = (unsigned*)(d + y * cairo_image_surface_get_stride(gShot)) + x;
    return (int)(*px & 0x00FFFFFF); /* ARGB32 native: rgb in the low bytes */
    }
/* Tests: the real "clicked" signal on a native button — GTK4's honest
 * stand-in for event injection; it IS the button's fire path. */
void ux_gtk_test_click(int handle, int node)
    {
    GtkWidget* c = gCtl[handle][node];
    if (GTK_IS_BUTTON(c))
        g_signal_emit_by_name(c, "clicked");
    }
/* the loop gate's rig: clicks and a watchdog as REAL GLib timer sources, so
 * they arrive through the same blocking wait the app idles in */
static gboolean click_cb(gpointer u)
    {
    long v = (long)u;
    ux_gtk_test_click((int)(v >> 8), (int)(v & 0xFF));
    return G_SOURCE_REMOVE;
    }
void ux_gtk_test_click_later(int handle, int node, int ms)
    {
    g_timeout_add(ms, click_cb, (gpointer)(long)((handle << 8) | node));
    }
static gboolean dog_cb(gpointer u)
    {
    fprintf(stderr, "ux_gtk: watchdog fired\n");
    exit((int)(long)u);
    }
void ux_gtk_test_watchdog(int ms, int rc)
    {
    g_timeout_add(ms, dog_cb, (gpointer)(long)rc);
    }

/* The smallest the window's content may be dragged to. */
void ux_gtk_window_set_min_size(int handle, int w, int h)
    {
    if (handle <= 0 || handle >= UXGTK_MAXW || !gWin[handle])
        return;
    gtk_widget_set_size_request(GTK_WIDGET(gWin[handle]), w, h);
    }

/* ── the item of an outline under a point ───────────────────────────────────── */
void* ux_gtk_outline_item_at(int handle, int node, int x, int y)
    {
    if (handle < 0 || handle >= UXGTK_MAXW || !gFix[handle])
        return NULL;
    GtkColumnView* cv = tbl_view(handle, node);
    if (!cv || !gtk_widget_get_visible(gCtl[handle][node]))
        return NULL;
    GtkWidget* w = gtk_widget_pick(GTK_WIDGET(gFix[handle]), x, y, GTK_PICK_DEFAULT);
    for (; w; w = gtk_widget_get_parent(w))
        {
        if (g_object_get_data(G_OBJECT(w), "ux-cv") == (gpointer)cv)
            return g_object_get_data(G_OBJECT(w), "ux-olitem");
        if (w == GTK_WIDGET(cv))
            return NULL;
        }
    return NULL;
    }

/* ── a connection's line above everything in a window ──────────────────────────
 * A drawing area over the whole content, kept last in the GtkFixed so it is drawn above the native
 * controls, and set to take no input, so every click goes through it. */
static GtkWidget* gLineW[UXGTK_MAXW];
static double gLine[UXGTK_MAXW][8]; /* x0 y0 x1 y1, then the framed rect */
static void line_draw(GtkDrawingArea* a, cairo_t* cr, int w, int h, gpointer hp)
    {
    (void)a; (void)w; (void)h;
    double* L = gLine[GPOINTER_TO_INT(hp)];
    cairo_set_source_rgb(cr, 0.15, 0.45, 0.95);
    cairo_set_line_width(cr, 2);
    if (L[6] > 0 && L[7] > 0)
        {
        cairo_rectangle(cr, L[4] - 1, L[5] - 1, L[6] + 2, L[7] + 2);
        cairo_stroke(cr);
        }
    /* the S-curve: level out of one end and into the other */
    double dx = L[2] - L[0];
    double k = fabs(dx) / 2 > 30 ? fabs(dx) / 2 : 30;
    double dir = dx < 0 ? -1 : 1;
    cairo_move_to(cr, L[0], L[1]);
    cairo_curve_to(cr, L[0] + dir * k, L[1], L[2] - dir * k, L[3], L[2], L[3]);
    cairo_stroke(cr);
    cairo_arc(cr, L[2], L[3], 3, 0, 2 * G_PI);
    cairo_fill(cr);
    }
void ux_gtk_window_line(int handle, int on, int x0, int y0, int x1, int y1, int hx, int hy, int hw, int hh)
    {
    if (handle < 0 || handle >= UXGTK_MAXW || !gFix[handle])
        return;
    if (!gLineW[handle])
        {
        gLineW[handle] = gtk_drawing_area_new();
        gtk_widget_set_can_target(gLineW[handle], FALSE);
        gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(gLineW[handle]), line_draw, GINT_TO_POINTER(handle), NULL);
        gtk_fixed_put(gFix[handle], gLineW[handle], 0, 0);
        }
    GtkWidget* lw = gLineW[handle];
    if (!on)
        {
        gtk_widget_set_visible(lw, FALSE);
        return;
        }
    double* L = gLine[handle];
    L[0] = x0; L[1] = y0; L[2] = x1; L[3] = y1; L[4] = hx; L[5] = hy; L[6] = hw; L[7] = hh;
    GtkWidget* fix = GTK_WIDGET(gFix[handle]);
    gtk_widget_set_size_request(lw, gtk_widget_get_width(fix), gtk_widget_get_height(fix));
    GtkWidget* last = gtk_widget_get_last_child(fix);
    if (last && last != lw)
        gtk_widget_insert_after(lw, fix, last);
    gtk_widget_set_visible(lw, TRUE);
    gtk_widget_queue_draw(lw);
    }
/* For tests: whether window `handle`'s line is up, and its far end. */
int ux_gtk_test_line(int handle, int* x1, int* y1)
    {
    if (handle < 0 || handle >= UXGTK_MAXW || !gLineW[handle] || !gtk_widget_get_visible(gLineW[handle]))
        return 0;
    *x1 = (int)gLine[handle][2];
    *y1 = (int)gLine[handle][3];
    return 1;
    }

/* ── a context menu ────────────────────────────────────────────────────────────
 * A popover of flat buttons at the point, run until it closes, so the pick comes back as a value as
 * it does on AppKit.  For tests, ux_gtk_test_menu_pick makes the next one answer at once. */
static int gMenuPick, gMenuTestPick = -2;
static char gMenuTestTitles[512];
void ux_gtk_test_menu_pick(int i)
    {
    gMenuTestPick = i;
    }
const char* ux_gtk_test_menu_titles(void)
    {
    return gMenuTestTitles;
    }
static void menu_item_clicked(GtkButton* b, gpointer pop)
    {
    gMenuPick = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "ux-index"));
    gtk_popover_popdown(GTK_POPOVER(pop));
    }
static void menu_closed(GtkPopover* p, gpointer loop)
    {
    (void)p;
    g_main_loop_quit((GMainLoop*)loop);
    }
int ux_gtk_menu_popup(int handle, const char** titles, const int* flags, int n, int x, int y)
    {
    if (handle < 0 || handle >= UXGTK_MAXW || !gFix[handle] || n <= 0)
        return -1;
    if (gMenuTestPick != -2)
        {
        int at = 0;
        gMenuTestTitles[0] = 0;
        for (int i = 0; i < n && at < (int)sizeof(gMenuTestTitles) - 2; i++)
            at += snprintf(gMenuTestTitles + at, sizeof(gMenuTestTitles) - (size_t)at, "%s%s",
                           i ? "|" : "", (flags[i] & 1) ? "-" : titles[i]);
        int p = gMenuTestPick;
        gMenuTestPick = -2;
        return p;
        }
    GtkWidget* pop = gtk_popover_new();
    GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    for (int i = 0; i < n; i++)
        {
        if (flags[i] & 1)
            {
            gtk_box_append(GTK_BOX(box), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
            continue;
            }
        GtkWidget* b = gtk_button_new_with_label(titles[i]);
        gtk_button_set_has_frame(GTK_BUTTON(b), FALSE);
        gtk_widget_set_halign(gtk_button_get_child(GTK_BUTTON(b)), GTK_ALIGN_START);
        gtk_widget_set_sensitive(b, (flags[i] & 2) ? FALSE : TRUE);
        g_object_set_data(G_OBJECT(b), "ux-index", GINT_TO_POINTER(i));
        g_signal_connect(b, "clicked", G_CALLBACK(menu_item_clicked), pop);
        gtk_box_append(GTK_BOX(box), b);
        }
    gtk_popover_set_child(GTK_POPOVER(pop), box);
    gtk_popover_set_has_arrow(GTK_POPOVER(pop), FALSE);
    gtk_widget_set_parent(pop, GTK_WIDGET(gFix[handle]));
    GdkRectangle r = {x, y, 1, 1};
    gtk_popover_set_pointing_to(GTK_POPOVER(pop), &r);
    gtk_popover_set_position(GTK_POPOVER(pop), GTK_POS_BOTTOM);
    GMainLoop* loop = g_main_loop_new(NULL, FALSE);
    g_signal_connect(pop, "closed", G_CALLBACK(menu_closed), loop);
    gMenuPick = -1;
    gtk_popover_popup(GTK_POPOVER(pop));
    g_main_loop_run(loop);
    g_main_loop_unref(loop);
    gtk_widget_unparent(pop);
    return gMenuPick;
    }

/* For tests: a row dropped on window `handle` at (x, y), or dragged over it (hover; -1, -1 gone),
   delivered as a real one is. */
int ux_gtk_test_drop_item(int handle, const char* text, int x, int y)
    {
    if (handle < 0 || handle >= UXGTK_MAXW || !gFix[handle] || !gItemDrop)
        return 0;
    gItemDrop(text, handle, x, y);
    return 1;
    }
int ux_gtk_test_hover_item(int handle, const char* text, int x, int y)
    {
    if (handle < 0 || handle >= UXGTK_MAXW || !gFix[handle] || !gItemHover)
        return 0;
    gItemHover(text, handle, x, y);
    return 1;
    }
/* For tests: what a drag of `item` out of the outline at `node` carries, into buf; 1 if it drags. */
int ux_gtk_test_outline_drag(int handle, int node, void* item, char* buf, int n)
    {
    if (n > 0)
        buf[0] = 0;
    GtkColumnView* cv = (handle >= 0 && handle < UXGTK_MAXW) ? tbl_view(handle, node) : NULL;
    void* peer = cv ? g_object_get_data(G_OBJECT(cv), "ux-peer") : NULL;
    const char* t = (peer && gOlDragText) ? gOlDragText(peer, item, 0) : NULL;
    if (!t)
        return 0;
    snprintf(buf, (size_t)n, "%s", t);
    return 1;
    }
/* For tests: what a drag of `row` out of the table at `node` carries; 1 if the table drags rows. */
int ux_gtk_test_row_drag(int handle, int node, int row, char* buf, int n)
    {
    if (n > 0)
        buf[0] = 0;
    GtkColumnView* cv = (handle >= 0 && handle < UXGTK_MAXW) ? tbl_view(handle, node) : NULL;
    void* peer = cv ? g_object_get_data(G_OBJECT(cv), "ux-peer") : NULL;
    if (!peer || !gTblDrags || !gTblDrags(peer) || !gTblCell)
        return 0;
    const char* t = gTblCell(peer, row, 0);
    snprintf(buf, (size_t)n, "%s", t ? t : "");
    return 1;
    }
/* For tests: let GTK lay out and draw for n frames' worth of time (about 16 ms each), so widgets
   made on demand, such as a list's rows, exist. */
void ux_gtk_frames(int n)
    {
    for (int i = 0; i < n; i++)
        {
        ux_gtk_pump();
        g_usleep(16000);
        }
    ux_gtk_pump();
    }

/* The text of a button, check box, radio button or label made earlier: it may have changed since.
   An equal text is left alone, so a pass that changes nothing redraws nothing. */
void ux_gtk_set_text(int handle, int node, const char* text)
    {
    if (handle < 0 || handle >= UXGTK_MAXW || node < 0 || node >= UXGTK_MAXN || !text)
        return;
    GtkWidget* w = gCtl[handle][node];
    if (!w)
        return;
    if (GTK_IS_CHECK_BUTTON(w))
        {
        const char* now = gtk_check_button_get_label(GTK_CHECK_BUTTON(w));
        if (!now || strcmp(now, text) != 0)
            gtk_check_button_set_label(GTK_CHECK_BUTTON(w), text);
        }
    else if (GTK_IS_BUTTON(w))
        {
        const char* now = gtk_button_get_label(GTK_BUTTON(w));
        if (!now || strcmp(now, text) != 0)
            gtk_button_set_label(GTK_BUTTON(w), text);
        }
    else if (GTK_IS_LABEL(w))
        {
        if (strcmp(gtk_label_get_text(GTK_LABEL(w)), text) != 0)
            gtk_label_set_text(GTK_LABEL(w), text);
        }
    }

/* For tests: the text a native button, check box, radio button or label shows, into buf. */
int ux_gtk_test_control_text(int handle, int node, char* buf, int n)
    {
    if (n > 0)
        buf[0] = 0;
    GtkWidget* w = (handle >= 0 && handle < UXGTK_MAXW && node >= 0 && node < UXGTK_MAXN) ? gCtl[handle][node] : NULL;
    const char* t = !w ? NULL
                  : GTK_IS_CHECK_BUTTON(w) ? gtk_check_button_get_label(GTK_CHECK_BUTTON(w))
                  : GTK_IS_BUTTON(w)       ? gtk_button_get_label(GTK_BUTTON(w))
                  : GTK_IS_LABEL(w)        ? gtk_label_get_text(GTK_LABEL(w)) : NULL;
    if (!t)
        return 0;
    snprintf(buf, (size_t)n, "%s", t);
    return 1;
    }

/* ── native text view (UXTextView): a GtkTextView in a GtkScrolledWindow ─────────────────────
 * The text crosses as UTF-8 and style runs of five ints (byte start, byte length, flags, colour,
 * size; flags 1 bold, 2 italic, 4 underline, 8 monospace, the paragraph's alignment in bits 4-5).
 * Each style is a tag named for it ("ux-b", "ux-c336699", "ux-s18", "ux-a2", ...), so reading the
 * content back reads the names, never the properties.  GTK gives typed text no tags, so an insert
 * the user makes takes the style before it (or the one chosen for typing at an empty selection).
 * The buffer's own undo is off: it does not record tag changes, so UXTextView keeps the undo and
 * the undo keys are passed to it. */
#define UX_TV_RUN 5
static GtkTextView* gTv[UXGTK_MAXW][UXGTK_MAXN];
typedef void (*ux_tv_fn)(int handle, int node);
typedef void (*ux_tv_undo_fn)(int handle, int node, int redo);
static ux_tv_fn gTvChanged, gTvSelected;
static ux_tv_undo_fn gTvUndo;
static int gTvQuiet;      /* a change the toolkit pushed is not reported back to it */
static int gTvPendAt = -1, gTvPendN = 0; /* the user's insert in flight: char offset and length */
static int gTvTyping[UXGTK_MAXW][UXGTK_MAXN][4]; /* set?, flags, colour, size: the style for typing */
static int gTvLastSel[UXGTK_MAXW][UXGTK_MAXN][2];
static int gTvChangedNow; /* the buffer just changed: the cursor move that follows is the typing's */
void ux_gtk_textview_set_hooks(void* changed, void* selected, void* undo)
    {
    gTvChanged = (ux_tv_fn)changed;
    gTvSelected = (ux_tv_fn)selected;
    gTvUndo = (ux_tv_undo_fn)undo;
    }
static GtkTextView* tv_at(int handle, int node)
    {
    if (handle < 0 || handle >= UXGTK_MAXW || node < 0 || node >= UXGTK_MAXN)
        return NULL;
    return gTv[handle][node];
    }
static char* tv_all(GtkTextBuffer* b)
    {
    GtkTextIter s, e;
    gtk_text_buffer_get_bounds(b, &s, &e);
    return gtk_text_buffer_get_text(b, &s, &e, TRUE);
    }
/* byte offset <-> character offset, against the buffer's whole text */
static int tv_char_of(const char* t, int bytes)
    {
    int n = (int)strlen(t);
    if (bytes <= 0)
        return 0;
    if (bytes > n)
        bytes = n;
    while (bytes > 0 && ((unsigned char)t[bytes] & 0xC0) == 0x80)
        bytes--;
    return (int)g_utf8_pointer_to_offset(t, t + bytes);
    }
static int tv_byte_of(const char* t, int chars)
    {
    long n = g_utf8_strlen(t, -1);
    if (chars <= 0)
        return 0;
    if (chars >= n)
        return (int)strlen(t);
    return (int)(g_utf8_offset_to_pointer(t, chars) - t);
    }
static GtkTextTag* tv_tag(GtkTextBuffer* b, const char* name)
    {
    GtkTextTagTable* tt = gtk_text_buffer_get_tag_table(b);
    GtkTextTag* t = gtk_text_tag_table_lookup(tt, name);
    if (t)
        return t;
    t = gtk_text_buffer_create_tag(b, name, NULL);
    if (!strcmp(name, "ux-b"))
        g_object_set(t, "weight", PANGO_WEIGHT_BOLD, NULL);
    else if (!strcmp(name, "ux-i"))
        g_object_set(t, "style", PANGO_STYLE_ITALIC, NULL);
    else if (!strcmp(name, "ux-u"))
        g_object_set(t, "underline", PANGO_UNDERLINE_SINGLE, NULL);
    else if (!strcmp(name, "ux-m"))
        g_object_set(t, "family", "monospace", NULL);
    else if (!strncmp(name, "ux-c", 4))
        {
        char css[16];
        snprintf(css, sizeof css, "#%s", name + 4);
        g_object_set(t, "foreground", css, NULL);
        }
    else if (!strncmp(name, "ux-s", 4))
        {
        /* a size is in the view's pixels, as on the other backends: an absolute size, which a
         * description with nothing else set applies alone */
        PangoFontDescription* d = pango_font_description_new();
        pango_font_description_set_absolute_size(d, atoi(name + 4) * PANGO_SCALE);
        g_object_set(t, "font-desc", d, NULL);
        pango_font_description_free(d);
        }
    else if (!strncmp(name, "ux-a", 4))
        {
        int a = atoi(name + 4);
        g_object_set(t, "justification", a == 1 ? GTK_JUSTIFY_RIGHT : a == 2 ? GTK_JUSTIFY_CENTER : GTK_JUSTIFY_FILL, NULL);
        }
    return t;
    }
static void tv_strip_one(GtkTextTag* tag, gpointer ud)
    {
    char* name = NULL;
    g_object_get(tag, "name", &name, NULL);
    if (name && !strncmp(name, "ux-", 3))
        {
        GtkTextIter* r = (GtkTextIter*)ud;
        gtk_text_buffer_remove_tag(gtk_text_iter_get_buffer(&r[0]), tag, &r[0], &r[1]);
        }
    g_free(name);
    }
/* the style (flags, colour, size) over chars [a, b): every ux tag off, then those it names on */
static void tv_style(GtkTextBuffer* b, int a, int z, int flags, int colour, int size)
    {
    GtkTextIter r[2];
    gtk_text_buffer_get_iter_at_offset(b, &r[0], a);
    gtk_text_buffer_get_iter_at_offset(b, &r[1], z);
    gtk_text_tag_table_foreach(gtk_text_buffer_get_tag_table(b), tv_strip_one, r);
    gtk_text_buffer_get_iter_at_offset(b, &r[0], a);
    gtk_text_buffer_get_iter_at_offset(b, &r[1], z);
    char name[24];
    if (flags & 1) gtk_text_buffer_apply_tag(b, tv_tag(b, "ux-b"), &r[0], &r[1]);
    if (flags & 2) gtk_text_buffer_apply_tag(b, tv_tag(b, "ux-i"), &r[0], &r[1]);
    if (flags & 4) gtk_text_buffer_apply_tag(b, tv_tag(b, "ux-u"), &r[0], &r[1]);
    if (flags & 8) gtk_text_buffer_apply_tag(b, tv_tag(b, "ux-m"), &r[0], &r[1]);
    if (colour & 0x1000000)
        {
        snprintf(name, sizeof name, "ux-c%06x", colour & 0xFFFFFF);
        gtk_text_buffer_apply_tag(b, tv_tag(b, name), &r[0], &r[1]);
        }
    if (size > 0)
        {
        snprintf(name, sizeof name, "ux-s%d", size);
        gtk_text_buffer_apply_tag(b, tv_tag(b, name), &r[0], &r[1]);
        }
    if ((flags >> 4) & 3)
        {
        snprintf(name, sizeof name, "ux-a%d", (flags >> 4) & 3);
        gtk_text_buffer_apply_tag(b, tv_tag(b, name), &r[0], &r[1]);
        }
    }
/* the style at a char: from its tags' names */
static void tv_style_at(GtkTextIter* it, int* flags, int* colour, int* size)
    {
    int f = 0, c = 0, z = 0;
    GSList* tags = gtk_text_iter_get_tags(it);
    for (GSList* l = tags; l; l = l->next)
        {
        char* name = NULL;
        g_object_get(l->data, "name", &name, NULL);
        if (name && !strncmp(name, "ux-", 3))
            {
            char k = name[3];
            if (k == 'b') f |= 1;
            else if (k == 'i') f |= 2;
            else if (k == 'u') f |= 4;
            else if (k == 'm') f |= 8;
            else if (k == 'c') c = 0x1000000 | (int)strtol(name + 4, NULL, 16);
            else if (k == 's') z = atoi(name + 4);
            else if (k == 'a') f |= (atoi(name + 4) & 3) << 4;
            }
        g_free(name);
        }
    g_slist_free(tags);
    *flags = f;
    *colour = c;
    *size = z;
    }
/* runs, relative to char offset `base` of text t, applied over the chars they cover */
static void tv_apply_runs(GtkTextBuffer* b, const char* t, int baseByte, const int* runs, int nruns)
    {
    for (int k = 0; k < nruns; k++)
        {
        int s = baseByte + runs[k * UX_TV_RUN], e = s + runs[k * UX_TV_RUN + 1];
        tv_style(b, tv_char_of(t, s), tv_char_of(t, e), runs[k * UX_TV_RUN + 2], runs[k * UX_TV_RUN + 3],
                 runs[k * UX_TV_RUN + 4]);
        }
    }
static void tv_insert_before(GtkTextBuffer* b, GtkTextIter* at, char* text, int len, gpointer ud)
    {
    (void)ud;
    if (gTvQuiet)
        return;
    gTvPendAt = gtk_text_iter_get_offset(at);
    gTvPendN = (int)g_utf8_strlen(text, len);
    }
static void tv_changed(GtkTextBuffer* b, gpointer ud)
    {
    GtkTextView* tv = GTK_TEXT_VIEW(ud);
    int h = hOf(GTK_WIDGET(tv)), n = nOf(GTK_WIDGET(tv));
    if (gTvQuiet)
        return;
    if (gTvPendAt >= 0)
        {
        /* the user's insert: the style chosen for typing, or the one before it */
        int f = 0, c = 0, z = 0;
        if (gTvTyping[h][n][0])
            {
            f = gTvTyping[h][n][1];
            c = gTvTyping[h][n][2];
            z = gTvTyping[h][n][3];
            gTvTyping[h][n][0] = 0;
            }
        else if (gTvPendAt > 0)
            {
            GtkTextIter it;
            gtk_text_buffer_get_iter_at_offset(b, &it, gTvPendAt - 1);
            tv_style_at(&it, &f, &c, &z);
            }
        else
            {
            GtkTextIter it;
            gtk_text_buffer_get_iter_at_offset(b, &it, gTvPendAt + gTvPendN);
            if (!gtk_text_iter_is_end(&it))
                tv_style_at(&it, &f, &c, &z);
            }
        int at = gTvPendAt;
        gTvPendAt = -1;
        tv_style(b, at, at + gTvPendN, f, c, z);
        }
    gTvChangedNow = 1;
    if (gTvChanged)
        gTvChanged(h, n);
    }
static void tv_selection_now(GtkTextBuffer* b, int* s8, int* l8)
    {
    GtkTextIter a, z;
    gtk_text_buffer_get_selection_bounds(b, &a, &z);
    char* t = tv_all(b);
    int x = tv_byte_of(t, gtk_text_iter_get_offset(&a)), y = tv_byte_of(t, gtk_text_iter_get_offset(&z));
    g_free(t);
    *s8 = x < y ? x : y;
    *l8 = x < y ? y - x : x - y;
    }
static void tv_mark_set(GtkTextBuffer* b, GtkTextIter* loc, GtkTextMark* mark, gpointer ud)
    {
    (void)loc;
    GtkTextView* tv = GTK_TEXT_VIEW(ud);
    if (gTvQuiet || (mark != gtk_text_buffer_get_insert(b) && mark != gtk_text_buffer_get_selection_bound(b)))
        return;
    int h = hOf(GTK_WIDGET(tv)), n = nOf(GTK_WIDGET(tv));
    int s = 0, l = 0;
    tv_selection_now(b, &s, &l);
    if (s == gTvLastSel[h][n][0] && l == gTvLastSel[h][n][1])
        return;
    gTvLastSel[h][n][0] = s;
    gTvLastSel[h][n][1] = l;
    if (gTvChangedNow)
        {
        gTvChangedNow = 0; /* the caret moving after the typing, not the user moving it */
        return;
        }
    gTvTyping[h][n][0] = 0;
    if (gTvSelected)
        gTvSelected(h, n);
    }
/* Control-Z, Shift-Control-Z and Control-Y go to the toolkit's undo; the view's other editing keys
 * (cut, copy, paste, select all) are its own.  Taken in the capture phase, before the window's
 * menu shortcuts. */
static gboolean tv_key(GtkEventControllerKey* k, guint keyval, guint code, GdkModifierType mods, gpointer ud)
    {
    (void)k;
    (void)code;
    GtkTextView* tv = GTK_TEXT_VIEW(ud);
    GdkModifierType m = mods & (GDK_CONTROL_MASK | GDK_SHIFT_MASK | GDK_ALT_MASK | GDK_META_MASK);
    if (!(m & (GDK_CONTROL_MASK | GDK_META_MASK)) || (m & GDK_ALT_MASK))
        return FALSE;
    guint key = gdk_keyval_to_lower(keyval);
    int h = hOf(GTK_WIDGET(tv)), n = nOf(GTK_WIDGET(tv));
    if (key == GDK_KEY_z || key == GDK_KEY_y)
        {
        if (gTvUndo)
            gTvUndo(h, n, (key == GDK_KEY_y || (m & GDK_SHIFT_MASK)) ? 1 : 0);
        return TRUE;
        }
    if (m & GDK_SHIFT_MASK)
        return FALSE;
    if (key == GDK_KEY_x)
        g_signal_emit_by_name(tv, "cut-clipboard");
    else if (key == GDK_KEY_c)
        g_signal_emit_by_name(tv, "copy-clipboard");
    else if (key == GDK_KEY_v)
        g_signal_emit_by_name(tv, "paste-clipboard");
    else if (key == GDK_KEY_a)
        g_signal_emit_by_name(tv, "select-all", TRUE);
    else
        return FALSE;
    return TRUE;
    }
void ux_gtk_make_textview(int handle, int node, int x, int y, int w, int h)
    {
    GtkWidget* sw = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sw), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_has_frame(GTK_SCROLLED_WINDOW(sw), TRUE);
    GtkWidget* tw = gtk_text_view_new();
    GtkTextView* tv = GTK_TEXT_VIEW(tw);
    gtk_text_view_set_wrap_mode(tv, GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_left_margin(tv, 4);
    gtk_text_view_set_right_margin(tv, 4);
    gtk_text_view_set_top_margin(tv, 3);
    GtkTextBuffer* b = gtk_text_view_get_buffer(tv);
    gtk_text_buffer_set_enable_undo(b, FALSE);
    g_object_set_data(G_OBJECT(tw), "ux-handle", GINT_TO_POINTER(handle));
    g_object_set_data(G_OBJECT(tw), "ux-node", GINT_TO_POINTER(node));
    g_signal_connect(b, "insert-text", G_CALLBACK(tv_insert_before), tv);
    g_signal_connect(b, "changed", G_CALLBACK(tv_changed), tv);
    g_signal_connect(b, "mark-set", G_CALLBACK(tv_mark_set), tv);
    GtkEventController* keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(tv_key), tv);
    gtk_widget_add_controller(tw, keys);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sw), tw);
    park(handle, node, sw, x, y, w, h);
    gTv[handle][node] = tv;
    memset(gTvTyping[handle][node], 0, sizeof gTvTyping[handle][node]);
    gTvLastSel[handle][node][0] = gTvLastSel[handle][node][1] = 0;
    }
void ux_gtk_textview_set_all(int handle, int node, const char* text, int nbytes, const int* runs, int nruns)
    {
    GtkTextView* tv = tv_at(handle, node);
    if (!tv)
        return;
    GtkTextBuffer* b = gtk_text_view_get_buffer(tv);
    gTvQuiet++;
    gtk_text_buffer_set_text(b, text ? text : "", nbytes);
    char* t = tv_all(b);
    tv_apply_runs(b, t, 0, runs, nruns);
    g_free(t);
    gTvQuiet--;
    }
void ux_gtk_textview_replace(int handle, int node, int start, int len, const char* text, int nbytes,
                             const int* runs, int nruns, int attrsOnly)
    {
    GtkTextView* tv = tv_at(handle, node);
    if (!tv)
        return;
    GtkTextBuffer* b = gtk_text_view_get_buffer(tv);
    gTvQuiet++;
    char* t = tv_all(b);
    int a = tv_char_of(t, start), z = tv_char_of(t, start + len);
    g_free(t);
    if (!attrsOnly)
        {
        GtkTextIter i0, i1;
        gtk_text_buffer_get_iter_at_offset(b, &i0, a);
        gtk_text_buffer_get_iter_at_offset(b, &i1, z);
        gtk_text_buffer_delete(b, &i0, &i1);
        gtk_text_buffer_get_iter_at_offset(b, &i0, a);
        gtk_text_buffer_insert(b, &i0, text ? text : "", nbytes);
        }
    t = tv_all(b);
    int e = tv_char_of(t, start + nbytes);
    tv_style(b, a, e, 0, 0, 0);
    tv_apply_runs(b, t, start, runs, nruns);
    g_free(t);
    gTvQuiet--;
    }
/* the runs the content has, and how many bytes: one pass that writes only when buf is given */
static int tv_walk(GtkTextBuffer* b, char* buf, int cap, int* runs, int maxRuns, int* nbytes)
    {
    GtkTextIter it, end;
    gtk_text_buffer_get_bounds(b, &it, &end);
    int k = 0, at = 0;
    int pf = -1, pc = 0, pz = 0;
    while (!gtk_text_iter_equal(&it, &end))
        {
        GtkTextIter next = it;
        if (!gtk_text_iter_forward_to_tag_toggle(&next, NULL))
            next = end;
        int f, c, z;
        tv_style_at(&it, &f, &c, &z);
        char* seg = gtk_text_buffer_get_text(b, &it, &next, TRUE);
        int n = (int)strlen(seg);
        if (buf && at + n < cap)
            memcpy(buf + at, seg, (size_t)n);
        g_free(seg);
        if (k > 0 && f == pf && c == pc && z == pz)
            {
            if (runs && k - 1 < maxRuns)
                runs[(k - 1) * UX_TV_RUN + 1] += n;
            }
        else
            {
            if (runs && k < maxRuns)
                {
                runs[k * UX_TV_RUN] = at;
                runs[k * UX_TV_RUN + 1] = n;
                runs[k * UX_TV_RUN + 2] = f;
                runs[k * UX_TV_RUN + 3] = c;
                runs[k * UX_TV_RUN + 4] = z;
                }
            k++;
            pf = f;
            pc = c;
            pz = z;
            }
        at += n;
        it = next;
        }
    if (buf && cap > 0)
        buf[at < cap ? at : cap - 1] = 0;
    if (nbytes)
        *nbytes = at;
    return k;
    }
void ux_gtk_textview_size(int handle, int node, int* nbytes, int* nruns)
    {
    GtkTextView* tv = tv_at(handle, node);
    *nbytes = 0;
    *nruns = 0;
    if (tv)
        *nruns = tv_walk(gtk_text_view_get_buffer(tv), NULL, 0, NULL, 0, nbytes);
    }
int ux_gtk_textview_read(int handle, int node, char* buf, int cap, int* runs, int maxRuns)
    {
    GtkTextView* tv = tv_at(handle, node);
    if (!tv || cap <= 0)
        return 0;
    int k = tv_walk(gtk_text_view_get_buffer(tv), buf, cap, runs, maxRuns, NULL);
    return k < maxRuns ? k : maxRuns;
    }
void ux_gtk_textview_selection(int handle, int node, int* start, int* len)
    {
    GtkTextView* tv = tv_at(handle, node);
    *start = 0;
    *len = 0;
    if (tv)
        tv_selection_now(gtk_text_view_get_buffer(tv), start, len);
    }
void ux_gtk_textview_set_selection(int handle, int node, int start, int len)
    {
    GtkTextView* tv = tv_at(handle, node);
    if (!tv)
        return;
    GtkTextBuffer* b = gtk_text_view_get_buffer(tv);
    char* t = tv_all(b);
    GtkTextIter a, z;
    gtk_text_buffer_get_iter_at_offset(b, &a, tv_char_of(t, start));
    gtk_text_buffer_get_iter_at_offset(b, &z, tv_char_of(t, start + len));
    g_free(t);
    gTvQuiet++;
    gtk_text_buffer_select_range(b, &z, &a);
    gtk_text_view_scroll_mark_onscreen(tv, gtk_text_buffer_get_insert(b));
    gTvQuiet--;
    gTvLastSel[handle][node][0] = start;
    gTvLastSel[handle][node][1] = len;
    }
void ux_gtk_textview_set_typing(int handle, int node, int flags, int colour, int size)
    {
    if (!tv_at(handle, node))
        return;
    gTvTyping[handle][node][0] = 1;
    gTvTyping[handle][node][1] = flags;
    gTvTyping[handle][node][2] = colour;
    gTvTyping[handle][node][3] = size;
    }
void ux_gtk_textview_focus(int handle, int node)
    {
    GtkTextView* tv = tv_at(handle, node);
    if (tv)
        gtk_widget_grab_focus(GTK_WIDGET(tv));
    }
/* The look, as CSS: each text view has a class of its own ("ux-tv-<handle>-<node>") and one
 * display-wide provider holds every view's rules, rebuilt when one changes.  Text with no tag of its
 * own takes the widget's colour, size and face, so reading the tags back is not affected. */
static char* gTvCss[UXGTK_MAXW][UXGTK_MAXN];
static GtkCssProvider* gTvCssProvider;
void ux_gtk_textview_set_look(int handle, int node, int bg, int ink, int caret, int sel, int size, int mono)
    {
    GtkTextView* tv = tv_at(handle, node);
    if (!tv)
        return;
    char cls[32];
    snprintf(cls, sizeof cls, "ux-tv-%d-%d", handle, node);
    gtk_widget_add_css_class(GTK_WIDGET(tv), cls);
    char rules[1024];
    int n = 0;
    n += snprintf(rules + n, sizeof rules - n, "textview.%s text {", cls);
    if (bg)
        n += snprintf(rules + n, sizeof rules - n, " background-color: #%06x;", bg & 0xFFFFFF);
    if (ink)
        n += snprintf(rules + n, sizeof rules - n, " color: #%06x;", ink & 0xFFFFFF);
    if (caret || ink)
        n += snprintf(rules + n, sizeof rules - n, " caret-color: #%06x;", (caret ? caret : ink) & 0xFFFFFF);
    if (size > 0)
        n += snprintf(rules + n, sizeof rules - n, " font-size: %dpx;", size);
    if (mono)
        n += snprintf(rules + n, sizeof rules - n, " font-family: monospace;");
    n += snprintf(rules + n, sizeof rules - n, " }\n");
    if (bg)
        n += snprintf(rules + n, sizeof rules - n, "textview.%s { background-color: #%06x; }\n", cls, bg & 0xFFFFFF);
    if (sel)
        n += snprintf(rules + n, sizeof rules - n, "textview.%s text selection { background-color: #%06x; }\n", cls,
                      sel & 0xFFFFFF);
    g_free(gTvCss[handle][node]);
    gTvCss[handle][node] = g_strdup(rules);
    GString* all = g_string_new("");
    for (int h = 0; h < UXGTK_MAXW; h++)
        for (int k = 0; k < UXGTK_MAXN; k++)
            if (gTvCss[h][k])
                g_string_append(all, gTvCss[h][k]);
    if (!gTvCssProvider)
        {
        gTvCssProvider = gtk_css_provider_new();
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(gTvCssProvider),
                                                   GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
#if GTK_CHECK_VERSION(4, 12, 0)
    gtk_css_provider_load_from_string(gTvCssProvider, all->str);
#else
    gtk_css_provider_load_from_data(gTvCssProvider, all->str, -1);
#endif
    g_string_free(all, TRUE);
    }
/* the rigs': text typed at the cursor as the user types it (the view reports the change) */
void ux_gtk_test_textview_type(int handle, int node, const char* text)
    {
    GtkTextView* tv = tv_at(handle, node);
    if (tv)
        gtk_text_buffer_insert_interactive_at_cursor(gtk_text_view_get_buffer(tv), text, -1, TRUE);
    }
/* ...and an editing key: Control (and Shift) with key, through the view's own key handler */
int ux_gtk_test_textview_key(int handle, int node, int key, int shift)
    {
    GtkTextView* tv = tv_at(handle, node);
    if (!tv)
        return 0;
    return tv_key(NULL, (guint)key, 0, GDK_CONTROL_MASK | (shift ? GDK_SHIFT_MASK : 0), tv) ? 1 : 0;
    }
