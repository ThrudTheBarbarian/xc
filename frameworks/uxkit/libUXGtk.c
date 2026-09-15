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

#define UXGTK_MAXW 64

typedef void (*ux_content_fn)(int handle, int wx, int wy, int ww, int wh, void* ud);
typedef void (*ux_fire_fn)(int handle, int node);
typedef void (*ux_value_fn)(int handle, int node, int value);
typedef void (*ux_field_fn)(int handle, int node);
typedef void (*ux_mouse_fn)(int kind, int x, int y, int handle);

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
static GtkWidget* gCtl[UXGTK_MAXW][256];
static char* gFieldBuf[UXGTK_MAXW * 256];
static int gFieldCap[UXGTK_MAXW * 256];
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

static gboolean event_cb(GtkEventControllerLegacy* c, GdkEvent* ev, gpointer ud)
    {
    int handle = GPOINTER_TO_INT(ud);
    GdkEventType t = gdk_event_get_event_type(ev);
    double x = 0, y = 0;
    if (t != GDK_BUTTON_PRESS && t != GDK_MOTION_NOTIFY && t != GDK_BUTTON_RELEASE)
        return FALSE;
    gdk_event_get_position(ev, &x, &y);
    gtk_to_area(handle, &x, &y);
    if (t == GDK_BUTTON_PRESS)
        {
        gPtrX = x;
        gPtrY = y;
        gBtnDown = 1;
        gPtrMoved = 0;
        if (gMouse)
            gMouse(1, (int)x, (int)y, handle); /* 1 == UXEventMouseDown */
        return FALSE;                          /* native widgets still get theirs */
        }
    if (t == GDK_MOTION_NOTIFY)
        {
        if ((int)x != (int)gPtrX || (int)y != (int)gPtrY)
            {
            gPtrX = x;
            gPtrY = y;
            gPtrMoved = 1;
            }
        return FALSE;
        }
    gBtnDown = 0; /* GDK_BUTTON_RELEASE */
    return FALSE;
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
        gMouse(1, x, y, handle);
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
    GtkWidget* c = (handle >= 0 && handle < UXGTK_MAXW && node >= 0 && node < 256)
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
    GtkWidget* c = (handle >= 0 && handle < UXGTK_MAXW && node >= 0 && node < 256)
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
    GtkWidget* c = (handle >= 0 && handle < UXGTK_MAXW && node >= 0 && node < 256)
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

static void draw_cb(GtkDrawingArea* a, cairo_t* cr, int w, int h, gpointer ud)
    {
    int handle = GPOINTER_TO_INT(ud);
    if (!gContent[handle])
        return;
    gCr = cr;
    gContent[handle](handle, 0, 0, w, h, gContentUd[handle]);
    gCr = NULL;
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
    gWin[hh] = win;
    gFix[hh] = fix;
    gArea[hh] = area;
    GtkEventController* ec = gtk_event_controller_legacy_new();
    g_signal_connect(ec, "event", G_CALLBACK(event_cb), GINT_TO_POINTER(hh));
    gtk_widget_add_controller(GTK_WIDGET(win), ec);
    gLive++;
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
    for (int n = 0; n < 256; n++)
        gCtl[handle][n] = NULL;
    gWin[handle] = NULL;
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
    }
void ux_gtk_content_geometry(int handle, int* w, int* h)
    {
    if (gWin[handle])
        gtk_window_get_default_size(gWin[handle], w, h);
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

static void toggled_cb(GtkCheckButton* c, gpointer ud)
    {
    if (gValue)
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
void ux_gtk_set_check(int handle, int node, int on)
    {
    GtkWidget* c = gCtl[handle][node];
    if (GTK_IS_CHECK_BUTTON(c))
        gtk_check_button_set_active(GTK_CHECK_BUTTON(c), on != 0);
    }

static void range_cb(GtkRange* r, gpointer ud)
    {
    if (gValue)
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
    if (GTK_IS_RANGE(c))
        gtk_range_set_value(GTK_RANGE(c), val);
    }

static void spin_cb(GtkSpinButton* s, gpointer ud)
    {
    if (gValue)
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
        gtk_spin_button_set_value(GTK_SPIN_BUTTON(c), val);
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
    if (gValue)
        gValue(hOf(GTK_WIDGET(d)), nOf(GTK_WIDGET(d)),
               (int)gtk_drop_down_get_selected(GTK_DROP_DOWN(d)));
    }
static GtkStringList* gPopupItems[UXGTK_MAXW * 256];
void ux_gtk_make_popup(int handle, int node, int x, int y, int w, int h)
    {
    GtkStringList* sl = gtk_string_list_new(NULL);
    gPopupItems[handle * 256 + node] = sl;
    GtkWidget* d = gtk_drop_down_new(G_LIST_MODEL(sl), NULL);
    g_signal_connect(d, "notify::selected", G_CALLBACK(dropdown_cb), NULL);
    park(handle, node, d, x, y, w, h);
    }
void ux_gtk_popup_add_item(int handle, int node, const char* title)
    {
    gtk_string_list_append(gPopupItems[handle * 256 + node], title);
    }
void ux_gtk_popup_select(int handle, int node, int i)
    {
    GtkWidget* c = gCtl[handle][node];
    if (GTK_IS_DROP_DOWN(c) && i >= 0)
        gtk_drop_down_set_selected(GTK_DROP_DOWN(c), i);
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
    char* buf = gFieldBuf[handle * 256 + node];
    int cap = gFieldCap[handle * 256 + node];
    if (buf && cap > 0)
        {
        const char* t = gtk_editable_get_text(e);
        strncpy(buf, t ? t : "", cap - 1);
        buf[cap - 1] = 0;
        }
    if (gField)
        gField(handle, node);
    }
void ux_gtk_make_field(int handle, int node, int x, int y, int w, int h,
                       char* buf, int cap, int secure)
    {
    GtkWidget* e = secure ? gtk_password_entry_new() : gtk_entry_new();
    if (buf && buf[0])
        gtk_editable_set_text(GTK_EDITABLE(e), buf);
    gFieldBuf[handle * 256 + node] = buf;
    gFieldCap[handle * 256 + node] = cap;
    g_signal_connect(e, "changed", G_CALLBACK(entry_cb), NULL);
    park(handle, node, e, x, y, w, h);
    }
void ux_gtk_update_field(int handle, int node)
    {
    GtkWidget* c = gCtl[handle][node];
    char* buf = gFieldBuf[handle * 256 + node];
    if (c && GTK_IS_EDITABLE(c) && buf)
        gtk_editable_set_text(GTK_EDITABLE(c), buf);
    }

/* ── drawing ops (the cairo of the draw in flight) ───────────────────────── */
static void setRGB(int r, int g, int b)
    {
    cairo_set_source_rgb(gCr, r / 255.0, g / 255.0, b / 255.0);
    }
void ux_gtk_fill(int x, int y, int w, int h, int r, int g, int b)
    {
    if (!gCr)
        return;
    setRGB(r, g, b);
    cairo_rectangle(gCr, x, y, w, h);
    cairo_fill(gCr);
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
void ux_gtk_poly(short* xy, int n, int r, int g, int b)
    {
    if (!gCr || n < 3)
        return;
    setRGB(r, g, b);
    cairo_move_to(gCr, xy[0], xy[1]);
    for (int i = 1; i < n; i++)
        cairo_line_to(gCr, xy[i * 2], xy[i * 2 + 1]);
    cairo_close_path(gCr);
    cairo_fill(gCr);
    }
void ux_gtk_text(const char* s, int x, int y, int r, int g, int b, int size)
    {
    if (!gCr)
        return;
    setRGB(r, g, b);
    cairo_select_font_face(gCr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(gCr, size > 0 ? size : 13);
    cairo_move_to(gCr, x, y + (size > 0 ? size : 13)); /* top-left in, baseline out */
    cairo_show_text(gCr, s);
    }
void ux_gtk_text_font(const char* s, int x, int y, int r, int g, int b,
                      const char* family, int size, int bold, int italic)
    {
    if (!gCr)
        return;
    setRGB(r, g, b);
    cairo_select_font_face(gCr, family && family[0] ? family : "sans-serif",
                           italic ? CAIRO_FONT_SLANT_ITALIC : CAIRO_FONT_SLANT_NORMAL,
                           bold ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(gCr, size > 0 ? size : 13);
    cairo_move_to(gCr, x, y + (size > 0 ? size : 13));
    cairo_show_text(gCr, s);
    }
void ux_gtk_stroke_path(int* ops, int n, int width, int startCap, int endCap,
                        int r, int g, int b)
    {
    if (!gCr || n <= 0 || width <= 0)
        return;
    setRGB(r, g, b);
    cairo_set_line_width(gCr, width);
    cairo_set_line_join(gCr, CAIRO_LINE_JOIN_ROUND);
    int cap = startCap > endCap ? startCap : endCap;
    cairo_set_line_cap(gCr, cap == 1   ? CAIRO_LINE_CAP_ROUND
                            : cap == 2 ? CAIRO_LINE_CAP_SQUARE
                                       : CAIRO_LINE_CAP_BUTT);
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
            cairo_close_path(gCr);
        else
            break;
        }
    cairo_stroke(gCr);
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
int ux_gtk_pixel(int x, int y)
    {
    if (!gShot)
        return -1;
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
