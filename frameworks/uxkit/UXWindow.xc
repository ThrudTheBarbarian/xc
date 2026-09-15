// UXWindow.xc — one AES window handle, one view tree.
//
// GEM draws the frame (title, closer, mover — all themed, none of it our problem).
// We supply the content, and the content is an OBJECT tree, so objc_draw walks it
// and every stock widget in it draws itself.
//
// The AES calls back through a bare C function pointer with a void* — xtc has no
// closures, so the UXWindow rides in that void*.  Proven in spikes/trampoline.xc.

#import "UXGeometry.xc"
#import "UXResponder.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXViewTree.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"
#import "UXViewDriver.xc"

// Posted (object = the UXWindow, a/b = the new content width/height) when the user resizes a window,
// for observers that are not the app delegate.  The app delegate also gets windowDidResize directly.
#define UXWindowDidResizeNotification (u8*)"UXWindowDidResize"

// Diagnostics: how many objects the AES VISITED (called us for), vs how many we
// actually drew.  The gap is the cost of the tree walk itself — GEM's draw_rec
// recurses every node regardless of the damage rect, and we can only decline to
// DRAW, not decline to be visited.  See test_scale.xc.
u32 gUserDrawVisits;
u32 gUserDrawDraws;

// ---- THE SEAM ---------------------------------------------------------------
// The AES invokes this for every G_USERDEF inside objc_draw.  It is drawRect.
i32 ux_userdraw(pointer tree, i32 obj, pointer ud)
    {
    gUserDrawVisits = gUserDrawVisits + (u32)1;
    UXWindow* w = (UXWindow*)ud; // the window, straight from the AES
    if (w == (UXWindow*)0)
        {
        return (i32)0;
        }

    UXViewTree* vt = w.tree;
    UXView* v = (UXView* ?)vt.viewAt((u16)obj);
    if (v == (UXView*)0)
        {
        return (i32)0;
        }

    UXRect abs = vt.absoluteFrame((u16)obj);

    // The VDI would clip our drawing anyway — but it cannot stop us DOING it.  A view
    // outside the damage rect is skipped before drawRect runs at all, which is the
    // difference between "one line of text repaints one line" and "one line of text
    // runs every drawRect in the window and throws the pixels away".
    if (w.hasDamage && !UXGeom.intersects(abs, w.damage))
        {
        return (i32)0;
        }

    gUserDrawDraws = gUserDrawDraws + (u32)1;
    UXGraphics* g = gDriver.beginViewDraw((i32)abs.x, (i32)abs.y, (i32)abs.w, (i32)abs.h);

    // Virtual dispatch into app code, from inside the backend's own traversal.
    v.drawRect(g, UXGeom.make((i16)0, (i16)0, abs.w, abs.h));
    return (i32)0;
    }

// The window's content callback: hand our tree to the AES.
void ux_window_draw(i32 handle, i32 wx, i32 wy, i32 ww, i32 wh, pointer ud)
    {
    UXWindow* w = (UXWindow*)ud;
    if (w == (UXWindow*)0)
        {
        return;
        }
    w.layoutFor(wx, wy, ww, wh);

    // The AES hands us the WORK AREA.  If we started this repaint we know something
    // narrower — the damage rect — so hand THAT to objc_draw as the clip.  (The VDI's
    // clip stack intersects, so we can only ever narrow, never widen: safe either way.)
    i32 cx = wx;
    i32 cy = wy;
    i32 cw = ww;
    i32 ch = wh;
    if (w.hasDamage)
        {
        cx = (i32)w.damage.x;
        cy = (i32)w.damage.y;
        cw = (i32)w.damage.w;
        ch = (i32)w.damage.h;
        }

    // Point the seam at THIS window for the duration of the walk.
    gDriver.treeSetUserDraw((pointer)&ux_userdraw, (pointer)w);
    gDriver.treeDraw((pointer)w.tree.objects(), (i32)0, cx, cy, cw, ch);
    }

class UXWindow : UXResponder
    {
    i32 handle;
    UXViewTree* tree;
    UXView* contentView;
    weak : UXResponder* firstResponder;
    // The button Return fires (an app-declared role, not a position — §5).  weak, for the
    // same reason action targets are: the window must not own a control in its own tree.
    weak : UXControl* defaultButton;
    // A hand-built content view fills the window.  A tree loaded from a .rsc has
    // its OWN size — the designer chose it — so we position it but never resize it.
    bool resizesContent;

    // The damage rect for the repaint currently in flight, if WE started it.  The
    // AES's content callback is handed the WORK AREA, not the damage — so the window
    // parks the rect here for the duration of its own wind_redraw_area().
    //
    // When the AES redraws us for its OWN reasons (first paint, resize) this is false
    // and we draw everything, which is correct: we were not told what changed.
    UXRect damage;
    bool hasDamage;

    // The content extent, as last reported to the AES.  0 = "never reported", which is
    // also "does not scroll" — the AES draws no bar and scroll_y stays 0.
    i16 contentW;
    i16 contentH;

    // The root's work-area size at the last layout, so springs & struts can compute the delta on the
    // backends where the NEUTRAL layer lays out (GEM/Win32).  0 = not laid out yet.
    i16 prevW;
    i16 prevH;

    void init(void)
        {
        super.init();
        handle = (i32)0;
        tree = new UXViewTree();
        contentView = (UXView*)0;
        firstResponder = (UXResponder*)0;
        defaultButton = (UXControl*)0;
        resizesContent = true;
        damage = UXGeom.zero();
        hasDamage = false;
        contentW = (i16)0;
        contentH = (i16)0;
        prevW = (i16)0;
        prevH = (i16)0;
        }

    // The content view is the tree's ROOT object — a G_BOX, so GEM paints the
    // window's background for us.
    void open(u8* title, UXRect f, UXView* content)
        {
        contentView = content;
        content.attachTo(tree, UXGeom.make((i16)0, (i16)0, f.w, f.h));
        content.setNextResponder(self); // the chain ends at the window

        handle = gDriver.windowCreate((i32)f.x, (i32)f.y, (i32)f.w, (i32)f.h);
        self.setTitle(title);
        gDriver.windowSetContent(handle, (pointer)&ux_window_draw, (pointer)self);
        gDriver.windowOpen(handle, (i32)f.x, (i32)f.y, (i32)f.w, (i32)f.h);
        tree.finalise();
        self.displayAll(); // first paint: everything
        }

    // Open a window whose content came out of a .rsc.  The resource's OBJECT tree
    // IS the view tree — nothing is converted.
    void openWithTree(u8* title, UXRect f, UXViewTree* vt)
        {
        tree = vt;
        resizesContent = false;                           // the resource decided its own size
        contentView = (UXView* ?)vt.viewAt((u16)0);       // the resource's root
        if (contentView != (UXView*)0)
            {
            contentView.setNextResponder(self);
            }

        handle = gDriver.windowCreate((i32)f.x, (i32)f.y, (i32)f.w, (i32)f.h);
        self.setTitle(title);
        gDriver.windowSetContent(handle, (pointer)&ux_window_draw, (pointer)self);
        gDriver.windowOpen(handle, (i32)f.x, (i32)f.y, (i32)f.w, (i32)f.h);
        self.displayAll(); // first paint: everything
        }

    // ---- chrome: DECLARATIVE (§11) ------------------------------------------
    // A client cannot draw in gemd's chrome, so chrome is a MODEL the native frame renders.
    // These are neutral now — the driver knows they are WF_* fields with a hi/lo pack, and
    // app code says setTitle("Rocks") and never sees it.
    void setTitle(u8* s)
        {
        gDriver.windowSetTitle(handle, s);
        }
    // a path, a second line
    void setSubtitle(u8* s)
        {
        gDriver.windowSetSubtitle(handle, s);
        }
    // the footer text
    void setInfo(u8* s)
        {
        gDriver.windowSetInfo(handle, s);
        }
    // a theme slice name
    void setIcon(u8* slice)
        {
        gDriver.windowSetIcon(handle, slice);
        }
    void setModified(bool m)
        {
        gDriver.windowSetModified(handle, m);
        }

    // Find a view by its object index — how an app reaches a control the nib made.
    // Rocks' symbolic export means this reads as views[MAIN_OK], not views[3].
    UXView* viewAt(u16 i)
        { return (UXView* ?)tree.viewAt(i);
        }

    // The AES gives us the work area on every draw; the root tracks it, so the
    // whole tree moves with the window for free (children are parent-relative).
    //
    // AND SO DOES SCROLLING.  The scrollbar is CHROME: gemd draws it, runs the thumb
    // drag, the arrow step, the track page and the mouse wheel, shrinks the work area
    // when the bar appears, and clamps the offset.  Our entire share of "scrolling" is
    // to subtract that offset here — the root moves, and every child is parent-relative,
    // so the whole tree scrolls.
    //
    // objc_find walks the SAME tree with the SAME root, so HIT-TESTING SCROLLS FOR FREE.
    // There is no "add scroll_y back into the click" anywhere in Xtg, because there is
    // nothing to add it back to: the objects really are where the click says they are.
    //
    // wind_scroll_y is 0 for a window that never reported a content size, so a
    // non-scrolling window pays one syscall-free read and behaves exactly as before.
    void layoutFor(i32 wx, i32 wy, i32 ww, i32 wh)
        {
        UXRect f = tree.frameOf((u16)0);
        i16 nx = (i16)(wx - gDriver.windowScrollX(handle));
        i16 ny = (i16)(wy - gDriver.windowScrollY(handle));
        i16 nw = f.w;
        i16 nh = f.h;
        if (resizesContent)
            {
            // Width always follows the work area — which the AES has ALREADY narrowed by
            // the bar's width, so the content reflows into the narrower span with no help
            // from us.  Height is the CONTENT's, not the window's: a tree squashed to the
            // visible height would have nothing to scroll to.
            nw = (i16)ww;
            nh = contentH > (i16)0 ? contentH : (i16)wh;
            }
        tree.setFrameOf((u16)0, UXGeom.make(nx, ny, nw, nh));

        // Springs & struts.  Where the neutral layer owns layout (GEM/Win32) this reflows everything.
        // On AppKit the native NSView masks already track the CONTROLS — but nothing tracks a
        // custom-drawn view, which has no NSView, so its frame stayed at its birth size for ever and
        // anything laying itself out from bounds() (wrapped text) never re-flowed.  So the walk runs
        // on every backend now; resizeSubviews is what declines to touch natively-tracked controls,
        // so the two still never both write the same frame.
        if (contentView != (UXView*)0)
            {
            if (prevW > (i16)0 && (nw != prevW || nh != prevH))
                {
                contentView.resizeSubviews((i32)prevW, (i32)prevH, (i32)nw, (i32)nh);
                }
            prevW = nw;
            prevH = nh;
            }
        }

    // ---- scrolling ------------------------------------------------------------
    // Report how big the content really is.  That is the ONLY thing the AES needs in
    // order to run a scrollbar for us: when contentH exceeds the work area it draws a
    // themed bar in the right border, shrinks the work area, and starts routing wheel
    // and thumb events to itself.  We draw no bar, track no thumb, and handle no wheel.
    //
    // Sent ONLY on change: apps report their size from inside the draw callback, and an
    // unconditional send would put a wire message on every single paint.
    void setContentSize(i16 w, i16 h)
        {
        if (w == contentW && h == contentH)
            {
            return;
            }
        contentW = w;
        contentH = h;
        gDriver.windowContentSize(handle, (i32)w, (i32)h);
        }

    i16 scrollX(void)
        {
        return (i16)gDriver.windowScrollX(handle);
        }
    i16 scrollY(void)
        {
        return (i16)gDriver.windowScrollY(handle);
        }

    // A REQUEST, not a command — the AES clamps it to [0, content - work] and the truth
    // is whatever scrollY() says afterwards, exactly as a rect is clamped (§11).
    void scrollTo(i16 x, i16 y)
        {
        gDriver.windowSetScroll(handle, (i32)x, (i32)y);
        }

    // Repaint ONLY WHAT CHANGED.  Nothing dirty -> nothing to do; this is called for
    // every window on every pass of the run loop, so a clean window must be free.
    void display(void)
        {
        if (!tree.isDirty())
            {
            return;
            }
        UXRect d = tree.takeDirty();
        damage = d;
        hasDamage = true;                            // ux_window_draw reads it back
        gDriver.realizeTree(handle, tree.objects()); // sync native control widgets (AppKit) — e.g.
                                                     // a setText from a menu action reaches the field
        gDriver.windowInvalidateRect(handle, (i32)d.x, (i32)d.y, (i32)d.w, (i32)d.h);
        hasDamage = false;
        }

    // Repaint everything: first paint, and a WM_REDRAW the AES asked for (where we
    // were not told what changed, so we must assume all of it).
    void displayAll(void)
        {
        tree.takeDirty();                            // subsumed by a full repaint
        gDriver.realizeTree(handle, tree.objects()); // sync any native control widgets (AppKit)
        gDriver.windowInvalidate(handle);
        }

    // Raise this window to the front and give it focus (a Windows-menu pick).
    void orderFront(void)
        {
        if (handle != (i32)0)
            {
            gDriver.windowOrderFront(handle);
            }
        }
    // false once close() ran (native window destroyed)
    bool isOpen(void)
        {
        return handle != (i32)0;
        }

    // ---- teardown ------------------------------------------------------------
    // Release the native window through the driver (on GEM: wind_close drops the window +
    // surface, wind_delete frees the handle slot, and the native-object counter drops).
    // UXWindow owns the "is it still open?" question — handle is zeroed after destroy, so a
    // second close (or dealloc after an explicit close) no-ops.
    void close(void)
        {
        if (handle == (i32)0)
            {
            return;
            }
        gDriver.windowDestroy(handle);
        handle = (i32)0;
        }

    // A window dropped without an explicit close must still release its native object — the
    // front object owning a native one is exactly the leak §10's gate guards against.  Just
    // close(): xtc's dealloc is non-re-entrant (the runtime bumps the refcount to a sentinel
    // for the duration of dealloc — COMPILER-THREAD.md #3, Task #622), so a self-dispatch here
    // whose callee makes an opaque call can't cycle the count to 0 and re-enter.
    void dealloc(void)
        {
        self.close();
        }

    // ---- the first responder -------------------------------------------------
    // The window owns it, not the view — a view must not know what a window is (that
    // import would be a cycle), and "who has the keyboard" is a per-window fact.
    //
    // The old responder may REFUSE to resign (a field with invalid contents), in which
    // case focus does not move.  That is the whole reason resignFirstResponder returns
    // a bool rather than being a notification.
    bool makeFirstResponder(UXResponder* r)
        {
        if (firstResponder == r)
            {
            return true;
            }
        if (firstResponder != (UXResponder*)0)
            {
            if (!firstResponder.resignFirstResponder())
                {
                return false;
                }
            }
        firstResponder = r;
        if (r != (UXResponder*)0)
            {
            return r.becomeFirstResponder();
            }
        return true;
        }

    // ---- keyboard navigation (§5) --------------------------------------------
    // The default button is app-declared (a ROLE, not a position) — Return fires it.
    void setDefaultButton(UXControl* b)
        {
        defaultButton = b;
        }

    // Move focus to the next focusable view, wrapping; reversed for Shift-Tab.  Tree
    // order IS tab order: the app builds the tree in the order it wants traversed, and
    // acceptsFirstResponder() decides who is a stop (a label is not, a field is).
    void moveFocus(bool forward)
        {
        u16 n = tree.length();
        if (n == (u16)0)
            {
            return;
            }
        i32 cur = (i32)-1;
        if (firstResponder != (UXResponder*)0)
            {
            for (u16 i = (u16)0; i < n; i = i + (u16)1)
                {
                if ((Object*)firstResponder == tree.viewAt(i))
                    {
                    cur = (i32)i;
                    break;
                    }
                }
            }
        i32 step = forward ? (i32)1 : (i32)-1;
        i32 idx = cur;
        for (u16 k = (u16)0; k < n; k = k + (u16)1)
            {
            idx = idx + step;
            if (idx < (i32)0)
                {
                idx = (i32)n - (i32)1;
                }
            if (idx >= (i32)n)
                {
                idx = (i32)0;
                }
            UXView* v = (UXView* ?)tree.viewAt((u16)idx);
            if (v != (UXView*)0 && v.acceptsFirstResponder())
                {
                self.makeFirstResponder(v);
                return;
                }
            }
        }

    // Keys that climbed the chain unconsumed land here: Tab traverses focus, Return fires
    // the default button, everything else climbs on to the application.
    void keyDown(UXEvent* e)
        {
        u16 ch = e.key & (u16)UX_KEY_ASCII;
        if (ch == (u16)UX_KEY_TAB)
            {
            self.moveFocus((e.modifiers & (u16)UX_MOD_SHIFT) == (u16)0);
            return;
            }
        if (ch == (u16)UX_KEY_RETURN && defaultButton != (UXControl*)0)
            {
            defaultButton.fire();
            return;
            }
        super.keyDown(e);
        }

    // A key arrived for this window.  The first responder gets first refusal; if there
    // is none, or it does not consume it, the chain carries it up to the window and
    // then the application.
    void dispatchKey(UXEvent* e)
        {
        if (firstResponder != (UXResponder*)0)
            {
            firstResponder.keyDown(e);
            return;
            }
        self.keyDown(e);
        }

    // A click landed in this window: let the AES find what was hit, then send it
    // into the responder chain.
    void dispatchMouse(UXEvent* e)
        {
        i32 hit = tree.hitTest(e.x, e.y);
        if (hit < (i32)0)
            {
            return;
            }
        Object* o = tree.viewAt((u16)hit);
        UXView* v = (UXView* ?)o;
        if (v == (UXView*)0)
            {
            return;
            }

        // Clicking something that wants the keyboard gives it the keyboard.  The WINDOW
        // does this, not the view, so UXView stays ignorant of windows.
        if (v.acceptsFirstResponder())
            {
            self.makeFirstResponder(v);
            }

        v.mouseDown(e); // climbs the chain if unhandled
        }

    // A wheel notch over the window: hit-test the point and hand it to that view; it climbs the
    // responder chain to the first thing that scrolls (a table).  No focus needed — the wheel acts
    // on what the pointer is over, which is exactly what gemd forwarded (the window under the cursor).
    void dispatchWheel(UXEvent* e)
        {
        i32 hit = tree.hitTest(e.x, e.y);
        if (hit < (i32)0)
            {
            return;
            }
        UXView* v = (UXView* ?)tree.viewAt((u16)hit);
        if (v == (UXView*)0)
            {
            return;
            }
        v.scrollWheel(e);
        }
    }
