// UXWebDriver.xc — the web realization of UXViewDriver (doc/UXKit-WEB-BACKEND.md).
//
// The fourth backend.  Where GEM had the AES's OBJECT[] and Win32 kept a shadow
// tree beside real HWNDs, this driver keeps the SAME shadow tree — a flat node
// array in linear memory, ported from UXWin32Driver — and draws everything onto
// a per-window canvas through the UXWeb.h.xc host imports.  Zero JS crossings
// for the entire structural half (§0); the host surface is the window group,
// the eight drawing primitives, and the ring.
//
// The run loop is the design's §3: the module runs in a Worker and the three
// blocking methods block on the loader's SAB ring (_xt_ring_wait).  Nothing
// here touches shared memory beyond that ring — one worker running the whole
// toolkit is single-threaded xtc (§3.1), and the atomic-ARC question stays
// unasked.
//
// Deliberately NOT here yet, each with its milestone in §5: menus (web-menu),
// alertRun across the ring (web-alert — returns the default for now, which the
// protocol permits), the <input> field overlay (web-field — editText's engine
// below covers ASCII), native panels (hasNative* answer false and the toolkit
// panels take over), and drag tracking (web-scroll).
#import <Stdio.xc>
#import "UXViewDriver.xc"
#import "UXWeb.h.xc"
#import "UXCanvasGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"
#import "UXLibc.xc"

// The draw-seam callbacks (call_indirect through a declared signature — the
// funcref-table rule in §4: these signatures ARE the ABI, and nothing casts
// an fn to a data pointer).
typedef void UXWebContentFn(i32 handle, i32 wx, i32 wy, i32 ww, i32 wh, pointer ud);
typedef i32 UXWebUserDrawFn(pointer tree, i32 obj, pointer ud);

// ── the shadow tree ─────────────────────────────────────────────────────────
// One node per view; identical shape to W32Node minus the native-control HWND
// (the web overlays come later, through structSetPeer, per §2).
struct WebNode
    {
    i32 kind;
    i16 x;
    i16 y;
    i16 w;
    i16 h;
    i16 hidden;
    i16 selected;
    i16 enabled;
    i16 clips;
    i16 selectable;
    i16 editable;
    pointer spec;
    i16 next;
    i16 head;
    i16 tail;
    i16 parent;
    pointer peer;
    } struct WebTree
    {
    WebNode* nodes;
    i32 count;
    i32 cap;
    }

    // A field editor: the app's buffer, capacity, optional validation — the same
    // record the Win32 driver keeps, driven by the same edit engine below.
    struct WebField
    {
    u8* buf;
    i32 cap;
    u8* valid;
    u8* place;
    i32 secure;
    }

// ── driver state ────────────────────────────────────────────────────────────
#define UXWEB_MAXW 64
    i32 gWebNative;        // §10 native-object counter (live windows)
i32 gWebLive[UXWEB_MAXW];  // handle -> live flag (JS mints handles 1..)
i32 gWebDirty[UXWEB_MAXW]; // handle -> needs-repaint flag
i16 gWebDirtyR[256];       // handle -> accumulated dirty rect (x,y,w,h per handle)
i32 gWebCw[UXWEB_MAXW];    // handle -> reported content size (scroll range)
i32 gWebCh[UXWEB_MAXW];
i32 gWebSx[UXWEB_MAXW]; // handle -> scroll offset (the toolkit owns it: §5 web-scroll)
i32 gWebSy[UXWEB_MAXW];
pointer gWebContentFn[UXWEB_MAXW];
pointer gWebContentUd[UXWEB_MAXW];
i32 gWebFront;      // topmost window (single canvas z-order, JS composites)
pointer gWebUserFn; // the per-view draw callback
pointer gWebUserUd;
UXCanvasGraphics* gWebGfx; // the one context, bound per paint
i32 gWebDrawOX;            // draw-origin offset for a scrolled subtree paint
i32 gWebDrawOY;
i32 gWebBooted;

class UXWebDriver : Object<UXViewDriver>
    {

    void init(void)
        {
        }

    // ---- boot / windows ------------------------------------------------------
    bool boot(i32* screenW, i32* screenH)
        {
        if (gWebBooted == (i32)0)
            {
            gWebGfx = new UXCanvasGraphics();
            gWebNative = (i32)0;
            gWebFront = (i32)0;
            gWebBooted = (i32)1;
            }
        return ux_boot(screenW, screenH) != (i32)0;
        }

    i32 windowCreate(i32 x, i32 y, i32 w, i32 h)
        {
        i32 hh = ux_win_create(x, y, w, h);
        if (hh <= (i32)0 || hh >= (i32)UXWEB_MAXW)
            {
            return (i32)0;
            }
        gWebLive[hh] = (i32)1;
        gWebDirty[hh] = (i32)0;
        gWebCw[hh] = (i32)0;
        gWebCh[hh] = (i32)0;
        gWebSx[hh] = (i32)0;
        gWebSy[hh] = (i32)0;
        gWebContentFn[hh] = (pointer)0;
        gWebContentUd[hh] = (pointer)0;
        gWebNative = gWebNative + (i32)1;
        return hh;
        }
    void windowSetContent(i32 handle, pointer fn, pointer ud)
        {
        gWebContentFn[handle] = fn;
        gWebContentUd[handle] = ud;
        }
    void windowOpen(i32 handle, i32 x, i32 y, i32 w, i32 h)
        {
        ux_win_open(handle, x, y, w, h);
        gWebFront = handle;
        self.windowInvalidate(handle);
        }
    void windowDestroy(i32 handle)
        {
        if (gWebLive[handle] == (i32)0)
            {
            return;
            }
        ux_win_destroy(handle);
        gWebLive[handle] = (i32)0;
        gWebDirty[handle] = (i32)0;
        gWebContentFn[handle] = (pointer)0;
        if (gWebFront == handle)
            {
            gWebFront = (i32)0;
            }
        gWebNative = gWebNative - (i32)1;
        }

    void windowSetTitle(i32 handle, u8* s)
        {
        ux_win_set_title(handle, s);
        }
    // no chrome equivalent (as Win32)
    void windowSetSubtitle(i32 handle, u8* s)
        {
        }
    void windowSetInfo(i32 handle, u8* s)
        {
        }
    void windowSetIcon(i32 handle, u8* slice)
        {
        }
    void windowSetModified(i32 handle, bool m)
        {
        }
    void windowOrderFront(i32 handle)
        {
        ux_win_order_front(handle);
        gWebFront = handle;
        }

    void windowContentSize(i32 handle, i32 w, i32 h)
        {
        gWebCw[handle] = w;
        gWebCh[handle] = h;
        }
    i32 windowScrollX(i32 handle)
        {
        return gWebSx[handle];
        }
    i32 windowScrollY(i32 handle)
        {
        return gWebSy[handle];
        }
    void windowSetScroll(i32 handle, i32 x, i32 y)
        {
        gWebSx[handle] = x;
        gWebSy[handle] = y;
        self.windowInvalidate(handle);
        }
    void windowContentGeometry(i32 handle, i32* w, i32* h)
        {
        ux_win_geometry(handle, w, h);
        }

    // ---- invalidation: accumulate, consolidate on present (§3.2) -------------
    // No canvas calls here — a dirty box and a flag.  The paint happens in
    // webPresent, once, under the consolidated clip: on the page that is the
    // requestAnimationFrame tick arriving through the ring; a headless test
    // calls webPresent itself, which is the same discipline the Win32 tests
    // apply through UpdateWindow.
    void windowInvalidateRect(i32 handle, i32 x, i32 y, i32 w, i32 h)
        {
        if (gWebLive[handle] == (i32)0)
            {
            return;
            }
        i32 s = handle * (i32)4;
        if (gWebDirty[handle] == (i32)0)
            {
            gWebDirtyR[s] = (i16)x;
            gWebDirtyR[s + (i32)1] = (i16)y;
            gWebDirtyR[s + (i32)2] = (i16)w;
            gWebDirtyR[s + (i32)3] = (i16)h;
            gWebDirty[handle] = (i32)1;
            return;
            }
        i32 x0 = (i32)gWebDirtyR[s];
        i32 y0 = (i32)gWebDirtyR[s + (i32)1];
        i32 x1 = x0 + (i32)gWebDirtyR[s + (i32)2];
        i32 y1 = y0 + (i32)gWebDirtyR[s + (i32)3];
        if (x < x0)
            {
            x0 = x;
            }
        if (y < y0)
            {
            y0 = y;
            }
        if (x + w > x1)
            {
            x1 = x + w;
            }
        if (y + h > y1)
            {
            y1 = y + h;
            }
        gWebDirtyR[s] = (i16)x0;
        gWebDirtyR[s + (i32)1] = (i16)y0;
        gWebDirtyR[s + (i32)2] = (i16)(x1 - x0);
        gWebDirtyR[s + (i32)3] = (i16)(y1 - y0);
        }
    void windowInvalidate(i32 handle)
        {
        i32 w = (i32)0;
        i32 h = (i32)0;
        if (gWebLive[handle] == (i32)0)
            {
            return;
            }
        ux_win_geometry(handle, &w, &h);
        gWebDirty[handle] = (i32)0; // full window supersedes any box
        self.windowInvalidateRect(handle, (i32)0, (i32)0, w, h);
        }
    // One consolidated repaint of one window: target, clip, content callback,
    // present.  The content callback is the neutral ux_window_draw, which walks
    // the view tree and comes back through treeDraw/beginViewDraw below.
    void webPresent(i32 handle)
        {
        if (gWebLive[handle] == (i32)0 || gWebDirty[handle] == (i32)0)
            {
            return;
            }
        if (gWebContentFn[handle] == (pointer)0)
            {
            gWebDirty[handle] = (i32)0;
            return;
            }
        i32 s = handle * (i32)4;
        ux_gfx_target(handle);
        ux_clip((i32)gWebDirtyR[s], (i32)gWebDirtyR[s + (i32)1],
                (i32)gWebDirtyR[s + (i32)2], (i32)gWebDirtyR[s + (i32)3]);
        UXWebContentFn* f = (UXWebContentFn*)gWebContentFn[handle];
        i32 w = (i32)0;
        i32 h = (i32)0;
        ux_win_geometry(handle, &w, &h);
        f(handle, (i32)0, (i32)0, w, h, gWebContentUd[handle]);
        ux_clip_end();
        ux_present(handle);
        gWebDirty[handle] = (i32)0;
        }
    void webPresentAll(void)
        {
        for (i32 i = (i32)1; i < (i32)UXWEB_MAXW; i = i + (i32)1)
            {
            if (gWebLive[i] != (i32)0)
                {
                self.webPresent(i);
                }
            }
        }

    // ---- native panels: none yet — the toolkit-drawn fallbacks take over -----
    bool hasNativeFileOpen(void)
        {
        return false;
        }
    i32 fileOpen(u8* prompt, u8* startDir, u8* out, i32 outCap)
        {
        return (i32)0;
        }
    bool hasNativeColorPicker(void)
        {
        return false;
        }
    i32 pickColor(i32 r, i32 g, i32 b, i32* outR, i32* outG, i32* outB)
        {
        return (i32)0;
        }
    bool hasNativeFontPicker(void)
        {
        return false;
        }
    i32 pickFont(u8* inFamily, i32 inSize, i32 inBold, i32 inItalic,
                 u8* outFamily, i32 outCap, i32* outSize, i32* outBold, i32* outItalic)
        {
        return (i32)0;
        }
    i32 listDir(u8* path, u8* out, i32 outCap)
        {
        return (i32)-1;
        }
    i32 fileDelete(u8* path)
        {
        return (i32)0;
        }
    i32 fileRename(u8* src, u8* dst)
        {
        return (i32)0;
        }
    i32 fileCopy(u8* src, u8* dst)
        {
        return (i32)0;
        }

    // ---- time / zone ---------------------------------------------------------
    i32 nowMs(void)
        {
        return time_ms();
        }
    void nowUTC(i32* out7)
        {
        ux_now_utc(out7);
        }
    i32 localOffsetMinutes(void)
        {
        return ux_tz_offmin();
        }

    // ---- settings (localStorage) ---------------------------------------------
    bool settingGet(u8* domain, u8* key, u8* out, i32 cap)
        {
        return ux_setting_get(domain, key, out, cap) != (i32)0;
        }
    bool settingSet(u8* domain, u8* key, u8* value)
        {
        return ux_setting_set(domain, key, value) != (i32)0;
        }
    bool settingRemove(u8* domain, u8* key)
        {
        return ux_setting_remove(domain, key) != (i32)0;
        }

    // ---- text measurement ----------------------------------------------------
    i32 textWidth(u8* s, i32 size)
        {
        return ux_text_width(s, (u8*)"", size, (i32)0, (i32)0);
        }
    i32 textWidthStyled(u8* s, u8* family, i32 size, bool bold, bool italic)
        {
        return ux_text_width(s, family, size, bold ? (i32)1 : (i32)0, italic ? (i32)1 : (i32)0);
        }

    // ---- popup / fonts -------------------------------------------------------
    i32 runPopupMenu(pointer peer, i32 x, i32 y)
        {
        return (i32)-1;
        }
    // The curated web-safe set (§2): what drawTextFont is later handed verbatim.
    i32 fontFamilyCount(void)
        {
        return (i32)4;
        }
    i32 fontFamilyName(i32 idx, u8* out, i32 cap)
        {
        u8* name = (u8*)0;
        if (idx == (i32)0)
            {
            name = (u8*)"system-ui";
            }
        else if (idx == (i32)1)
            {
            name = (u8*)"Georgia";
            }
        else if (idx == (i32)2)
            {
            name = (u8*)"Courier New";
            }
        else if (idx == (i32)3)
            {
            name = (u8*)"Arial";
            }
        else
            {
            return (i32)-1;
            }
        i32 i = (i32)0;
        while (name[i] != (u8)0 && i < cap - (i32)1)
            {
            out[i] = name[i];
            i = i + (i32)1;
            }
        out[i] = (u8)0;
        return i;
        }

    // ---- the shadow tree (ported from UXWin32Driver) -------------------------
    pointer structNew(void)
        {
        WebTree* t = (WebTree*)malloc((u32)sizeof(WebTree));
        t.cap = (i32)16;
        t.count = (i32)0;
        t.nodes = (WebNode*)calloc((u32)t.cap, (u32)sizeof(WebNode));
        return (pointer)t;
        }
    void structFree(pointer h)
        {
        if (h == (pointer)0)
            {
            return;
            }
        WebTree* t = (WebTree*)h;
        if (t.nodes != (WebNode*)0)
            {
            free((pointer)t.nodes);
            }
        free(h);
        }
    // no .rsc on the web
    void structAdopt(pointer h, pointer t, i32 n)
        {
        }
    pointer structObjects(pointer h)
        {
        return h;
        }
    i32 structLength(pointer h)
        {
        return ((WebTree*)h).count;
        }

    void structGrow(pointer h, i32 want)
        {
        WebTree* t = (WebTree*)h;
        if (want <= t.cap)
            {
            return;
            }
        i32 cap = t.cap;
        while (cap < want)
            {
            cap = cap * (i32)2;
            }
        t.nodes = (WebNode*)realloc((pointer)t.nodes, (u32)cap * (u32)sizeof(WebNode));
        t.cap = cap;
        }
    i32 structAppend(pointer h, i32 kind, i32 x, i32 y, i32 w, i32 ht)
        {
        WebTree* t = (WebTree*)h;
        self.structGrow(h, t.count + (i32)1);
        i32 i = t.count;
        WebNode* n = &t.nodes[i];
        n.kind = kind;
        n.x = (i16)x;
        n.y = (i16)y;
        n.w = (i16)w;
        n.h = (i16)ht;
        n.hidden = (i16)0;
        n.selected = (i16)0;
        n.enabled = (i16)1;
        n.clips = (i16)0;
        n.selectable = (i16)0;
        n.editable = (i16)0;
        n.spec = (pointer)0;
        n.next = (i16)-1;
        n.head = (i16)-1;
        n.tail = (i16)-1;
        n.parent = (i16)-1;
        n.peer = (pointer)0;
        t.count = i + (i32)1;
        return i;
        }
    void structAddChild(pointer h, i32 parent, i32 child)
        {
        WebNode* t = ((WebTree*)h).nodes;
        t[child].parent = (i16)parent;
        t[child].next = (i16)-1;
        if (t[parent].head == (i16)-1)
            {
            t[parent].head = (i16)child;
            }
        else
            {
            t[t[parent].tail].next = (i16)child;
            }
        t[parent].tail = (i16)child;
        }
    void structRemoveChild(pointer h, i32 parent, i32 child)
        {
        WebNode* t = ((WebTree*)h).nodes;
        i16 c = t[parent].head;
        if (c == (i16)child)
            {
            t[parent].head = t[child].next;
            }
        else
            {
            while (c != (i16)-1 && t[c].next != (i16)child)
                {
                c = t[c].next;
                }
            if (c != (i16)-1)
                {
                t[c].next = t[child].next;
                }
            }
        if (t[parent].tail == (i16)child)
            {
            t[parent].tail = c;
            }
        t[child].next = (i16)-1;
        t[child].parent = (i16)-1;
        }
    void structFinalise(pointer h)
        {
        }

    void structSetFrame(pointer h, i32 i, i32 x, i32 y, i32 w, i32 ht)
        {
        WebNode* n = &((WebTree*)h).nodes[i];
        n.x = (i16)x;
        n.y = (i16)y;
        n.w = (i16)w;
        n.h = (i16)ht;
        }
    void structFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
        {
        WebNode* n = &((WebTree*)h).nodes[i];
        x[0] = (i32)n.x;
        y[0] = (i32)n.y;
        w[0] = (i32)n.w;
        ht[0] = (i32)n.h;
        }
    void structSetHidden(pointer h, i32 i, i32 on)
        {
        ((WebTree*)h).nodes[i].hidden = (i16)on;
        }
    i32 structIsHidden(pointer h, i32 i)
        {
        return (i32)((WebTree*)h).nodes[i].hidden;
        }
    void structSetEnabled(pointer h, i32 i, i32 on)
        {
        ((WebTree*)h).nodes[i].enabled = (i16)on;
        }
    i32 structIsEnabled(pointer h, i32 i)
        {
        return (i32)((WebTree*)h).nodes[i].enabled;
        }
    void structSetSelected(pointer h, i32 i, i32 on)
        {
        ((WebTree*)h).nodes[i].selected = (i16)on;
        }
    i32 structIsSelected(pointer h, i32 i)
        {
        return (i32)((WebTree*)h).nodes[i].selected;
        }
    void structSetClips(pointer h, i32 i, i32 on)
        {
        ((WebTree*)h).nodes[i].clips = (i16)on;
        }
    void structSetSpec(pointer h, i32 i, pointer spec)
        {
        ((WebTree*)h).nodes[i].spec = spec;
        }
    void structSetPeer(pointer h, i32 i, pointer peer)
        {
        ((WebTree*)h).nodes[i].peer = peer;
        }
    // the neutral layer lays the web out
    void structSetAutoresize(pointer h, i32 i, i32 mask)
        {
        }
    bool driverAutoresizes(void)
        {
        return false;
        }
    void structSetSelectable(pointer h, i32 i, i32 on)
        {
        ((WebTree*)h).nodes[i].selectable = (i16)on;
        }
    void structSetEditable(pointer h, i32 i, i32 on)
        {
        ((WebTree*)h).nodes[i].editable = (i16)on;
        }

    void treeOffset(pointer tree, i32 obj, i32* ax, i32* ay)
        {
        ax[0] = (i32)0;
        ay[0] = (i32)0;
        }
    void structAbsFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
        {
        WebNode* t = ((WebTree*)h).nodes;
        i32 ax = (i32)t[i].x;
        i32 ay = (i32)t[i].y;
        i16 p = t[i].parent;
        while (p >= (i16)0)
            {
            ax = ax + (i32)t[p].x;
            ay = ay + (i32)t[p].y;
            p = t[p].parent;
            }
        x[0] = ax;
        y[0] = ay;
        w[0] = (i32)t[i].w;
        ht[0] = (i32)t[i].h;
        }

    // Deepest visible node whose absolute rect contains (px,py), or -1.
    i32 hitOne(WebNode* t, i32 i, i32 ox, i32 oy, i32 px, i32 py)
        {
        if (i < (i32)0 || t[i].hidden != (i16)0)
            {
            return (i32)-1;
            }
        i32 ax = ox + (i32)t[i].x;
        i32 ay = oy + (i32)t[i].y;
        i32 inside = (px >= ax && px < ax + (i32)t[i].w && py >= ay && py < ay + (i32)t[i].h) ? (i32)1 : (i32)0;
        i32 best = inside != (i32)0 ? i : (i32)-1;
        i16 c = t[i].head;
        while (c >= (i16)0)
            {
            i32 hc = self.hitOne(t, (i32)c, ax, ay, px, py);
            if (hc >= (i32)0)
                {
                best = hc;
                }
            c = t[c].next;
            }
        return best;
        }
    i32 treeHitTest(pointer tree, i32 start, i32 x, i32 y)
        {
        return self.hitOne(((WebTree*)tree).nodes, start, (i32)0, (i32)0, x, y);
        }

    // ---- painting ------------------------------------------------------------
    void treeSetUserDraw(pointer fn, pointer ud)
        {
        gWebUserFn = fn;
        gWebUserUd = ud;
        }
    // UXKindShield is NOT realized here: this backend puts native widgets on
    // screen, so a press on one is consumed before the toolkit sees it, and a
    // design surface (an editor canvas whose clicks select rather than operate)
    // would not yet work.  Nothing in-tree needs it on this backend today.  To
    // close it, mirror the AppKit driver: a bare native view above the controls
    // that forwards its press to the toolkit in content coordinates, then check
    // it the way appkit-shield does -- with a REAL injected press, because the
    // only question is what the platform does with it.
    // DOM overlays come later (§2)
    void realizeTree(i32 handle, pointer tree)
        {
        }

    // Walk the shadow tree; a custom view calls back into drawRect, the stock
    // kinds paint canvas fallbacks — the same fallbacks the Win32 driver draws
    // when a node has no native control, which on the web is every node.
    void drawOne(WebTree* t, i32 i)
        {
        if (i < (i32)0 || t.nodes[i].hidden != (i16)0)
            {
            return;
            }
        i32 k = t.nodes[i].kind;
        i32 ax = (i32)0;
        i32 ay = (i32)0;
        i32 w = (i32)0;
        i32 hh = (i32)0;
        // The GEM rule, kept exactly: everything that is not one of the four
        // natively-fallback kinds below is APP-DRAWN through the userdraw seam
        // (View, and every custom-drawn control: checkbox, radio, slider,
        // stepper, popup, progress, segmented, ...).  Restricting this to
        // UXKindView left every custom control BLANK on the web — found by
        // the capture pipeline's first slider portrait.
        bool fallback = k == (i32)UXKindButton || k == (i32)UXKindField || k == (i32)UXKindTable || k == (i32)UXKindLabel;
        if (!fallback && gWebUserFn != (pointer)0)
            {
            UXWebUserDrawFn* f = (UXWebUserDrawFn*)gWebUserFn;
            f((pointer)t.nodes, i, gWebUserUd);
            }
        else if (k == (i32)UXKindButton)
            {
            self.structAbsFrame((pointer)t, i, &ax, &ay, &w, &hh);
            // The Aristo art, exactly as the design doc planned drawTheme:
            // a 9-slice from the theme atlas; the shim's stand-in is a flat
            // face when no theme is loaded.  Title centred by measurement.
            u8* slice = t.nodes[i].enabled != (i16)0
                            ? (t.nodes[i].selected != (i16)0 ? (u8*)"button.selected" : (u8*)"button")
                            : (u8*)"button.disabled";
            ux_draw_theme(slice, ax, ay, w, hh);
            if (t.nodes[i].spec != (pointer)0)
                {
                u8* title = (u8*)t.nodes[i].spec;
                i32 tw = ux_text_width(title, (u8*)"", (i32)0, (i32)0, (i32)0);
                i32 grey = t.nodes[i].enabled != (i16)0 ? (i32)40 : (i32)128;
                ux_draw_text(title, ax + (w - tw) / (i32)2, ay + (hh - (i32)16) / (i32)2,
                             (u8*)"", (i32)0, (i32)0, (i32)0, grey, grey, grey);
                }
            }
        else if (k == (i32)UXKindField)
            {
            self.structAbsFrame((pointer)t, i, &ax, &ay, &w, &hh);
            ux_draw_theme((u8*)"textfield", ax, ay, w, hh);
            WebField* f = (WebField*)t.nodes[i].spec;
            if (f != (WebField*)0 && f.buf[0] != (u8)0)
                {
                // a secure field masks every glyph — the state-pair portrait
                // caught this drawing "secret" in the clear
                u8 shown[128];
                u8* src = &f.buf[0];
                if (f.secure != (i32)0)
                    {
                    i32 n = (i32)0;
                    while (src[n] != (u8)0 && n < (i32)127)
                        {
                        shown[n] = (u8)42;
                        n = n + (i32)1;
                        }
                    shown[n] = (u8)0;
                    src = &shown[(i32)0];
                    }
                ux_draw_text(src, ax + (i32)4, ay + (i32)3,
                             (u8*)"", (i32)0, (i32)0, (i32)0, (i32)0, (i32)0, (i32)0);
                }
            }
        else if (k == (i32)UXKindTable)
            {
            self.structAbsFrame((pointer)t, i, &ax, &ay, &w, &hh);
            ux_fill_rect(ax, ay, w, hh, (i32)255, (i32)255, (i32)255);
            ux_stroke_rect_edges(ax, ay, w, hh);
            }
        else if (k == (i32)UXKindLabel && t.nodes[i].spec != (pointer)0)
            {
            self.structAbsFrame((pointer)t, i, &ax, &ay, &w, &hh);
            ux_draw_text((u8*)t.nodes[i].spec, ax + (i32)2, ay + (i32)2,
                         (u8*)"", (i32)0, (i32)0, (i32)0, (i32)0, (i32)0, (i32)0);
            }
        // A clipping node (a scroll view's viewport) confines its SUBTREE — the
        // document is taller than the clip and draws at fixed coordinates, so
        // without this it bleeds over the neighbours (the sheet-2 outline cell
        // wore the scroll view's stripes).
        bool clips = t.nodes[i].clips != (i16)0;
        if (clips)
            {
            self.structAbsFrame((pointer)t, i, &ax, &ay, &w, &hh);
            ux_clip(ax, ay, w, hh);
            }
        i16 c = t.nodes[i].head;
        while (c >= (i16)0)
            {
            self.drawOne(t, (i32)c);
            c = t.nodes[c].next;
            }
        if (clips)
            {
            ux_clip_end();
            }
        }
    void treeDraw(pointer tree, i32 start, i32 clx, i32 cly, i32 clw, i32 clh)
        {
        self.drawOne((WebTree*)tree, start);
        }
    UXGraphics* beginViewDraw(i32 ax, i32 ay, i32 aw, i32 ah)
        {
        gWebGfx.bind(UXGeom.make((i16)(ax - gWebDrawOX), (i16)(ay - gWebDrawOY), (i16)aw, (i16)ah));
        return gWebGfx;
        }
    void setDrawOffset(i32 x, i32 y)
        {
        gWebDrawOX = x;
        gWebDrawOY = y;
        }
    // the canvas owns nothing: the toolkit's offset is the truth
    bool scrollsNatively(void)
        {
        return false;
        }
    void nativeScrollTo(pointer h, i32 node, i32 px)
        {
        }
    i32 nativeScrollPx(pointer h, i32 node)
        {
        return (i32)0;
        }

    // ---- text editing (the Win32 edit engine, verbatim) ----------------------
    pointer fieldEditorNew(u8* buf, i32 cap)
        {
        WebField* f = (WebField*)malloc((u32)sizeof(WebField));
        f.buf = buf;
        f.cap = cap;
        f.valid = (u8*)0;
        f.place = (u8*)0;
        f.secure = (i32)0;
        return (pointer)f;
        }
    void fieldEditorSetValid(pointer ed, u8* valid)
        {
        ((WebField*)ed).valid = valid;
        }
    void fieldEditorSetPlaceholder(pointer ed, u8* s)
        {
        ((WebField*)ed).place = s;
        }
    void fieldEditorSetSecure(pointer ed, i32 on)
        {
        ((WebField*)ed).secure = on;
        }
    void fieldEditorFree(pointer ed)
        {
        if (ed != (pointer)0)
            {
            free(ed);
            }
        }

    bool validOk(u8 code, i32 ch)
        {
        // '9'
        if (code == (u8)57)
            {
            return ch >= (i32)48 && ch <= (i32)57;
            }
        // 'A'
        if (code == (u8)65)
            {
            return (ch >= (i32)65 && ch <= (i32)90) || ch == (i32)32;
            }
        // 'a'
        if (code == (u8)97)
            {
            return (ch >= (i32)97 && ch <= (i32)122) || (ch >= (i32)65 && ch <= (i32)90);
            }
        return true; // 'X' / anything
        }
    i32 editText(pointer tree, i32 obj, i32 key, i32* caret, i32 mode)
        {
        WebField* f = (WebField*)((WebTree*)tree).nodes[obj].spec;
        if (f == (WebField*)0)
            {
            return (i32)0;
            }
        u8* b = f.buf;
        i32 len = (i32)0;
        while (b[len] != (u8)0)
            {
            len = len + (i32)1;
            }
        i32 c = caret[0];
        if (c < (i32)0)
            {
            c = (i32)0;
            }
        if (c > len)
            {
            c = len;
            }
        if (mode == (i32)UXEditBegin || mode == (i32)UXEditEnd)
            {
            caret[0] = len;
            return (i32)1;
            }
        i32 ch = key & (i32)$FF;
        // Backspace
        if (ch == (i32)8)
            {
            if (c <= (i32)0)
                {
                return (i32)0;
                }
            for (i32 i = c - (i32)1; i < len; i = i + (i32)1)
                {
                b[i] = b[i + (i32)1];
                }
            caret[0] = c - (i32)1;
            return (i32)1;
            }
        // not printable
        if (ch < (i32)32 || ch > (i32)126)
            {
            return (i32)0;
            }
        // full
        if (len + (i32)1 >= f.cap)
            {
            return (i32)0;
            }
        if (f.valid != (u8*)0)
            {
            i32 vlen = (i32)0;
            while (f.valid[vlen] != (u8)0)
                {
                vlen = vlen + (i32)1;
                }
            u8 code = c < vlen ? f.valid[c] : (u8)88; // past the mask: 'X'
            if (!self.validOk(code, ch))
                {
                return (i32)0;
                }
            }
        for (i32 i = len; i >= c; i = i - (i32)1)
            {
            b[i + (i32)1] = b[i];
            }
        b[c] = (u8)ch;
        caret[0] = c + (i32)1;
        return (i32)1;
        }

    // ---- menus / alerts: their milestones come later (§5) --------------------
    pointer menuBuild(pointer defs, i32 n, i32 screenW)
        {
        return (pointer)0;
        }
    void menuShow(pointer menu, i32 show)
        {
        }
    i32 menuItemOrd(pointer menu, i32 titleOrd, i32 itemObj)
        {
        return (i32)-1;
        }
    void menuCheck(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
        {
        }
    void menuEnable(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
        {
        }
    // Modal, §3's second blocking primitive: post the request (the worker-side
    // shim reads the strings out of module memory — nothing raw crosses), then
    // block until the answer comes back through the ring as a type-7 event.
    // Outside a worker (the plain recording rig) the shim answers the default
    // synchronously, so headless tests keep their old behaviour.
    i32 alertRun(i32 icon, u8* lines, u8* buttons, i32 defaultBtn)
        {
        return _xt_req_block((i32)1, (i32)lines, (i32)buttons, (icon << (i32)8) | defaultBtn);
        }

    // ---- events (§3: the ring) -----------------------------------------------
    // The loader's event slots are [type, a, b, ...]: 1/2/3 mouse down/up/move
    // (a=x, b=y, c=button), 4/5 key down/up (a=keyCode), 6 an animation tick
    // the page pushes for the §3.2 consolidation.  window coordinates ARE
    // canvas coordinates until multi-window compositing lands.
    void decodeRing(i32* r, UXEvent* ev)
        {
        i32 t = r[0];
        if (t == (i32)1)
            {
            ev.kind = (u8)UXEventMouseDown;
            ev.x = (i16)r[1];
            ev.y = (i16)r[2];
            ev.buttons = (u16)1;
            }
        else if (t == (i32)2)
            {
            ev.kind = (u8)UXEventMouseUp;
            ev.x = (i16)r[1];
            ev.y = (i16)r[2];
            ev.buttons = (u16)0;
            }
        else if (t == (i32)3)
            {
            ev.kind = (u8)UXEventMouseDragged;
            ev.x = (i16)r[1];
            ev.y = (i16)r[2];
            }
        else if (t == (i32)4)
            {
            ev.kind = (u8)UXEventKeyDown;
            ev.key = (u16)r[1];
            }
        else if (t == (i32)6)
            {
            self.webPresentAll();
            ev.kind = (u8)UXEventNone;
            }
        else
            {
            ev.kind = (u8)UXEventNone;
            }
        ev.handle = gWebFront;
        }
    void nextEvent(i32 timeoutMs, UXEvent* ev)
        {
        i32 r[8];
        ev.init();
        // timed out: UXEventNone
        if (_xt_ring_wait(timeoutMs) == (i32)0)
            {
            return;
            }
        if (_xt_ring_read(&r[0]) < (i32)0)
            {
            return;
            }
        self.decodeRing(&r[0], ev);
        }
    void pumpMessages(i32 timeoutMs, UXEvent* ev)
        {
        // Drain ticks without consuming input: present accumulated damage, and
        // leave anything that is real input in the ring for nextEvent.
        ev.init();
        self.webPresentAll();
        }
    i32 windowAtPoint(i32 x, i32 y)
        {
        return gWebFront;
        }
    // A toolkit-drawn drag (slider knob, scrollbar thumb, split divider):
    // block on the ring once per step — §3's third blocking primitive.  A
    // move returns 1 with the point (window coords ARE canvas coords), the
    // release ends the drag with 0.  Ticks present accumulated damage so the
    // drag paints live; a quiet ring ends the drag rather than wedging the
    // worker.  (§5 web-scroll's seam: the scrollbar drag rides this.)
    i32 trackDragStep(i32* x, i32* y)
        {
        if (gInputReplay)
            {
            return (i32)0;
            }
        i32 r[8];
        for (;;)
            {
            if (_xt_ring_wait((i32)4000) == (i32)0)
                {
                return (i32)0;
                }
            if (_xt_ring_read(&r[0]) < (i32)0)
                {
                return (i32)0;
                }
            if (r[0] == (i32)3)
                {
                x[0] = r[1];
                y[0] = r[2];
                return (i32)1;
                }
            if (r[0] == (i32)2)
                {
                return (i32)0;
                }
            if (r[0] == (i32)6)
                {
                self.webPresentAll();
                }
            }
        }

    i32 liveNativeCount(void)
        {
        return gWebNative;
        }
    i32 formFactorClass(void)
        {
        return (i32)UX_FORM_DESKTOP;
        }
    bool driverOwnsRunLoop(void)
        {
        return false;
        }
    void runLoop(void)
        {
        }
    }
