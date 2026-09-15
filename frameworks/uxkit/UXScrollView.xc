// UXScrollView.xc — a generic vertical scroller: a clipped viewport over a taller DOCUMENT view, with
// an optional pinned header strip and a scrollbar (track + up/down arrows + a draggable thumb).
//
// This is the reusable machinery that UXTableView (and, next, UXOutlineView) sits on: put a tall view
// in the document, tell the scroller how tall it is, and it clips + scrolls it — wheel, arrows, paging,
// thumb-drag, all live.  GEM draws the bar itself; win32/AppKit overlay a native table over the whole
// thing and never draw this subtree (their draw walk bails at UXKindTable), so the custom bar is the
// GEM box path's business only.
//
// The document is MOVED, not re-laid-out: scrolling sets the document view's y to -scrollOffset and the
// clip view cuts it to the viewport, so a client's content keeps fixed coordinates and objc_find still
// hit-tests it where it's drawn (the same trick UXWindow uses for whole-window scroll).
#import "UXView.xc"
#import "UXEvent.xc"
#import "UXGraphics.xc"
#import "UXApplication.xc" // gApp — to repaint mid thumb-drag (the run loop is parked then)

// The scrollbar widget.  Generic: it reads its geometry from an UXScrollView and drives it.
class UXScrollbar : UXView
    {
    weak : UXScrollView* scroll;
    void init(void)
        {
        super.init();
        scroll = (UXScrollView*)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }

    // Square arrow boxes at each end; the thumb rides the track between them.
    i16 arrowH(void)
        {
        return self.bounds().w;
        }
    i32 trackTop(void)
        {
        return (i32)self.arrowH();
        }
    i32 trackH(void)
        {
        return (i32)self.bounds().h - (i32)2 * (i32)self.arrowH();
        }
    i32 thumbH(void)
        {
        i32 content = scroll.contentPx();
        i32 view = (i32)self.bounds().h;
        i32 tr = self.trackH();
        if (content <= (i32)0 || tr <= (i32)0)
            {
            return tr;
            }
        i32 th = tr * view / content;
        if (th < (i32)20)
            {
            th = (i32)20;
            }
        if (th > tr)
            {
            th = tr;
            }
        return th;
        }
    i32 thumbY(void)
        {
        i32 mo = scroll.maxScroll();
        i32 span = self.trackH() - self.thumbH();
        return self.trackTop() + (mo > (i32)0 ? span * scroll.scrollPx() / mo : (i32)0);
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        if (scroll == (UXScrollView*)0)
            {
            return;
            }
        UXRect b = self.bounds();
        i16 aw = self.arrowH();
        g.fillRect(b, (i32)9);                           // mid-grey track
        g.drawLine((i16)0, (i16)0, (i16)0, b.h, (i32)1); // rule on the left edge
        i16 cx = (i16)(b.w / (i16)2);
        g.fillTriangle(cx, (i16)4, (i16)(cx - (i16)4), (i16)(aw - (i16)5),
                       (i16)(cx + (i16)4), (i16)(aw - (i16)5), (i32)1); // up arrow
        i16 dtop = (i16)((i32)b.h - (i32)aw);
        g.fillTriangle(cx, (i16)((i32)b.h - (i32)5), (i16)(cx - (i16)4), (i16)((i32)dtop + (i32)4),
                       (i16)(cx + (i16)4), (i16)((i32)dtop + (i32)4), (i32)1); // down arrow
        g.drawLine((i16)0, aw, b.w, aw, (i32)1);
        g.drawLine((i16)0, dtop, b.w, dtop, (i32)1);
        // fits: no thumb
        if (scroll.contentPx() <= (i32)b.h || self.trackH() <= (i32)0)
            {
            return;
            }
        i32 ty = self.thumbY();
        i32 th = self.thumbH();
        UXRect thumb = UXGeom.make((i16)2, (i16)ty, (i16)(b.w - (i16)3), (i16)th);
        g.fillRect(thumb, (i32)8); // lighter raised thumb
        g.drawLine((i16)2, (i16)ty, (i16)(b.w - (i16)1), (i16)ty, (i32)1);
        g.drawLine((i16)2, (i16)((i32)ty + th - (i32)1), (i16)(b.w - (i16)1), (i16)((i32)ty + th - (i32)1), (i32)1);
        g.drawLine((i16)2, (i16)ty, (i16)2, (i16)((i32)ty + th - (i32)1), (i32)1);
        g.drawLine((i16)(b.w - (i16)1), (i16)ty, (i16)(b.w - (i16)1), (i16)((i32)ty + th - (i32)1), (i32)1);
        }

    void mouseDown(UXEvent* e)
        {
        if (scroll == (UXScrollView*)0)
            {
            return;
            }
        UXRect b = self.bounds();
        i16 aw = self.arrowH();
        i32 localY = (i32)e.y - (i32)self.absoluteFrame().y;
        // up arrow
        if (localY < (i32)aw)
            {
            scroll.scrollByLines((i32)-1);
            return;
            }
        // down arrow
        if (localY >= (i32)b.h - (i32)aw)
            {
            scroll.scrollByLines((i32)1);
            return;
            }
        i32 ty = self.thumbY();
        i32 th = self.thumbH();
        // track above -> page up
        if (localY < ty)
            {
            scroll.scrollPage((i32)-1);
            return;
            }
        // track below -> page down
        if (localY >= ty + th)
            {
            scroll.scrollPage((i32)1);
            return;
            }
        self.dragThumb((i32)(localY - ty)); // on the thumb -> drag
        }

    // Drag the thumb: keep the grab point under the pointer, mapping the thumb's track position back to
    // a scroll offset each step (live — the run loop is parked in trackDragStep).
    void dragThumb(i32 grabDY)
        {
        i32 barAbsY = (i32)self.absoluteFrame().y;
        i32 th = self.thumbH();
        i32 span = self.trackH() - th;
        i32 mo = scroll.maxScroll();
        i32 x = (i32)0;
        i32 y = (i32)0;
        while (gDriver.trackDragStep(&x, &y) != (i32)0)
            {
            i32 top = (y - barAbsY) - self.trackTop() - grabDY;
            i32 off = span > (i32)0 ? mo * top / span : (i32)0;
            scroll.scrollTo((i16)off);
            if (gApp != (UXApplication*)0)
                {
                gApp.displayIfNeeded();
                }
            }
        }
    }

    class UXScrollView : UXView
    {
    UXView* clip;              // the clipped viewport
    UXView* doc;               // the document, moved by -scrollOffset inside the clip
    UXScrollbar* vbar;         // the vertical bar (right edge; hidden when the document fits)
    weak : UXView* headerView; // an optional strip pinned above the viewport (a table's column header)
    i16 scrollOffset;          // px scrolled down (0 = top)
    i16 sbWidth;               // bar column width
    i16 headerH;               // pinned header height (0 = none)
    i16 lineHeight;            // arrow/wheel step
    i32 docHeight;             // the document's content height

    void init(void)
        {
        super.init();
        clip = (UXView*)0;
        doc = (UXView*)0;
        vbar = (UXScrollbar*)0;
        headerView = (UXView*)0;
        scrollOffset = (i16)0;
        sbWidth = (i16)14;
        headerH = (i16)0;
        lineHeight = (i16)16;
        docHeight = (i32)0;
        }
    // UXKindScroll: GEM draws the custom bar + clips the document itself (falls through to G_USERDEF,
    // like a plain view); win32/AppKit map it to a native scroll container overlaying this subtree.
    UXKind kind(void)
        {
        return UXKindScroll;
        }

    // Build the viewport + document + bar as soon as we're in the tree (owner/index are live here).
    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        t.setPeerOf(index, (pointer)self); // a native scroll container reads content height off this
        clip = new UXView();
        self.addSubview(clip, UXGeom.make((i16)0, (i16)0, frame.w, frame.h));
        owner.setClipsOf(clip.index, true);
        clip.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        doc = new UXView();
        clip.addSubview(doc, UXGeom.make((i16)0, (i16)0, frame.w, frame.h));
        vbar = new UXScrollbar();
        vbar.scroll = self;
        self.addSubview(vbar, UXGeom.make((i16)((i32)frame.w - (i32)sbWidth), (i16)0, sbWidth, frame.h));
        vbar.setAutoresizeMask((i32)UX_ANCHOR_RIGHT | (i32)UX_FLEX_HEIGHT);
        }

    // ---- client surface -------------------------------------------------------
    // put your content in here
    UXView* document(void)
        {
        return doc;
        }
    void setLineHeight(i16 h)
        {
        lineHeight = h;
        }
    void setHeaderView(UXView* hv, i16 h)
        {
        headerView = hv;
        headerH = h;
        self.relayout();
        }
    void setDocumentHeight(i32 h)
        {
        docHeight = h;
        if (doc != (UXView*)0)
            {
            UXRect f = doc.frame();
            owner.setFrameOf(doc.index, UXGeom.make(f.x, f.y, f.w, (i16)h));
            }
        self.relayout();
        }

    // ---- scroll geometry ------------------------------------------------------
    i32 contentPx(void)
        {
        return docHeight;
        }
    i32 viewportPx(void)
        {
        return clip != (UXView*)0 ? (i32)clip.frame().h : (i32)self.frame().h - (i32)headerH;
        }
    // Where the view actually sits.  On a native backend the CONTAINER is the truth — the user can
    // drag its scroller without the toolkit hearing about it — so ask it rather than report the last
    // value we asked for.
    i32 scrollPx(void)
        {
        if (gDriver != (UXViewDriver*)0 && gDriver.scrollsNatively())
            {
            return gDriver.nativeScrollPx(owner.objects(), (i32)self.index);
            }
        return (i32)scrollOffset;
        }
    i32 maxScroll(void)
        {
        i32 m = docHeight - self.viewportPx();
        return m > (i32)0 ? m : (i32)0;
        }
    bool needsBar(void)
        {
        return docHeight > self.viewportPx();
        }

    // Size the viewport (narrower when a bar shows), place the header + bar, clamp + move the document.
    void relayout(void)
        {
        if (clip == (UXView*)0)
            {
            return;
            }
        UXRect f = self.frame();
        bool bar = self.needsBar();
        i16 vw = bar ? (i16)((i32)f.w - (i32)sbWidth) : f.w;
        i16 vh = (i16)((i32)f.h - (i32)headerH);
        owner.setFrameOf(clip.index, UXGeom.make((i16)0, headerH, vw, vh));
        owner.setFrameOf(vbar.index, UXGeom.make((i16)((i32)f.w - (i32)sbWidth), headerH, sbWidth, vh));
        owner.setHiddenOf(vbar.index, !bar);
        i16 mo = (i16)self.maxScroll();
        if (scrollOffset > mo)
            {
            scrollOffset = mo;
            }
        // Only shift the document where the TOOLKIT owns the offset.  A native container scrolls its
        // own document view, so shifting this one too would move the content twice.
        i16 docY = gDriver.scrollsNatively() ? (i16)0 : (i16)(-(i32)scrollOffset);
        owner.setFrameOf(doc.index, UXGeom.make((i16)0, docY, vw, (i16)docHeight));
        }

    // ---- native bridge (win32/AppKit map to a real scroll container over this subtree) --------
    i32 nativeContentHeight(void)
        {
        return docHeight;
        }
    i32 nativeDocNode(void)
        {
        return doc != (UXView*)0 ? (i32)doc.index : (i32)-1;
        }

    void scrollTo(i16 off)
        {
        i16 mo = (i16)self.maxScroll();
        if (off < (i16)0)
            {
            off = (i16)0;
            }
        if (off > mo)
            {
            off = mo;
            }
        if (off == scrollOffset)
            {
            return;
            }
        scrollOffset = off;
        // Where a NATIVE container owns the offset (Win32/AppKit), drive it and leave the document
        // node at 0 — moving it as well would double-scroll.  This used to return early instead, so
        // scrolling from code did nothing at all on those two backends: no reveal-a-row, no restoring
        // a saved position, and a recorded scroll that replayed as silence.
        if (gDriver.scrollsNatively())
            {
            gDriver.nativeScrollTo(owner.objects(), (i32)self.index, (i32)off);
            }
        else
            {
            owner.setFrameOf(doc.index, UXGeom.make((i16)0, (i16)(-(i32)off), doc.frame().w, (i16)docHeight));
            clip.setNeedsDisplay();
            if (vbar != (UXScrollbar*)0)
                {
                vbar.setNeedsDisplay();
                }
            }
        // Tell the tap where we ended up.  A drag is modal and emits nothing, so this is the only
        // trace a recorder can keep of a scroll — and it is enough to put the view back.  Suppressed
        // during a replay: the replayed event is what moved us, and re-announcing it would append to
        // a recording that is being played, not made.
        if (gEventTap != (callback void(UXEvent * e))0 && !gInputReplay)
            {
            UXEvent* ev = new UXEvent();
            ev.kind = (u8)UXEventScrolled;
            ev.a = (i32)self.index;
            ev.b = (i32)off;
            gEventTap(ev);
            }
        }
    void scrollByLines(i32 lines)
        {
        self.scrollTo((i16)((i32)scrollOffset + lines * (i32)lineHeight));
        }
    void scrollPage(i32 dir)
        {
        i32 page = self.viewportPx() - (i32)lineHeight;
        if (page < (i32)lineHeight)
            {
            page = (i32)lineHeight;
            }
        self.scrollTo((i16)((i32)scrollOffset + dir * page));
        }
    // A wheel that climbed the responder chain to here (gemd: notches > 0 = wheel up = toward the top).
    void scrollWheel(UXEvent* e)
        {
        self.scrollByLines((i32)0 - (i32)e.a * (i32)3);
        }
    }

    // ---- native sub-surface draw (AppKit) ---------------------------------------------------------
    // The native scroll container (NSScrollView) draws the scroll view's DOCUMENT subtree into its own
    // document view, which is a second surface at its own origin.  So draw the subtree with the driver's
    // draw-offset set to the document node's absolute position: every view then lands at doc-local coords,
    // and the native container owns the scroll offset.  (Only AppKit calls this; GEM/win32 draw inline.)
    i32 ux_scroll_userdraw(pointer tree, i32 obj, pointer ud)
    {
    UXViewTree* vt = (UXViewTree*)ud;
    UXView* v = (UXView* ?)vt.viewAt((u16)obj);
    if (v == (UXView*)0)
        {
        return (i32)0;
        }
    UXRect abs = vt.absoluteFrame((u16)obj);
    UXGraphics* g = gDriver.beginViewDraw((i32)abs.x, (i32)abs.y, (i32)abs.w, (i32)abs.h);
    v.drawRect(g, UXGeom.make((i16)0, (i16)0, abs.w, abs.h));
    return (i32)0;
    }
void ux_scroll_draw(pointer sp, i32 docW, i32 docH)
    {
    UXScrollView* sv = (UXScrollView*)sp;
    if (sv == (UXScrollView*)0)
        {
        return;
        }
    i32 docNode = sv.nativeDocNode();
    if (docNode < (i32)0)
        {
        return;
        }
    UXViewTree* vt = sv.document().owner;
    UXRect docAbs = vt.absoluteFrame((u16)docNode);
    gDriver.setDrawOffset((i32)docAbs.x, (i32)docAbs.y); // abs -> doc-local in beginViewDraw
    gDriver.treeSetUserDraw((pointer)&ux_scroll_userdraw, (pointer)vt);
    gDriver.treeDraw((pointer)vt.objects(), docNode, (i32)0, (i32)0, docW, docH);
    gDriver.setDrawOffset((i32)0, (i32)0);
    }
