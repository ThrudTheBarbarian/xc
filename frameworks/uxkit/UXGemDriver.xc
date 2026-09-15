// UXGemDriver.xc — the GEM realization of UXViewDriver.
//
// Every op here is the wind_*/objc_* call that used to sit inline in UXWindow.  Moving it
// behind the driver is what makes room for a second backend: a Win32 driver is this file
// with CreateWindowEx / DestroyWindow in place of wind_create / wind_close+wind_delete.
//
// The native object on GEM is the gemd window (the handle) + its surface.  wind_close tells
// gemd to drop the window and free the surface (and unmaps our view of it); wind_delete
// frees the client-side handle slot — both are needed (the AES menu.c pattern).

#import <Stdio.xc>
#import "UXViewDriver.xc"
#import "UXGem.h.xc"
#import "UXGem.xc"         // UX_DEPTH (how deep objc_draw / objc_find descend)
#import "UXGemGraphics.xc" // the driver owns the drawing context it hands to drawRect
#import "UXEvent.xc"       // nextEvent decodes the native message into a neutral UXEvent
#import "UXString.xc"      // building form_alert's "[icon][lines][buttons]" string
#import "UXPopUpButton.xc" // runPopupMenu reads the peer's items — this driver runs the menu itself

// The §10 native-object counter, driver-module global (it counts natives of THIS backend,
// not per-view state).  liveNativeCount() exposes it; the memory gate asserts it balances.
i32 gGemNativeLive;

// A per-tree GEM structure: the OBJECT[] the AES actually walks, plus its bookkeeping.  §6:
// the driver owns structure, so this lives here, not in the generic UXViewTree — which holds
// it only as an opaque handle and never names OBJECT.  A malloc'd record of raw pointers, not
// an ARC object.
struct UXGemTree
    {
    OBJECT* tree;
    i32 count;
    i32 cap;
    i32 owns;
    }

    // The C-ABI shape of libGEM's menu_def {const char*, const char**, int}.  xtc PACKS the neutral
    // UXMenuDef (20 bytes on 64-bit — no trailing pad), but C PADS menu_def to 24 (three pointer slots),
    // so passing the neutral array straight to menu_build reads the 2nd+ menu at the wrong stride ->
    // garbage -> crash.  Three pointer-sized slots match C's stride on both arches (nitems rides in the
    // third slot; C reads its low int).  Local to the GEM path — AppKit/Win32 read the neutral struct in
    // xtc, self-consistently, so they need no repack.
    struct GemMenuDef
    {
    pointer title;
    pointer items;
    pointer nitems;
    }

    // The theme (256 slices, ~19.5KB — DWARF gives the real size) and the back-buffer surface.
    // Both are backend state, and both MUST outlive boot(): vdi_init() STORES the surface
    // pointer (gem/vdi/core.c: ws_tab[0].target) rather than copying it, so a stack local would
    // leave the VDI holding dead stack the moment boot() returned — every later
    // vdi_screen_target() would then read garbage and wind_redraw_area() would bail before it
    // reached the content callback.  Module globals keep them alive for the process.
    theme gGemTheme;
gfx_surface gGemBackBuffer;

// The one drawing context the driver reuses per paint — bound to the view being drawn and
// handed back through the UXGraphics protocol, so the draw seam never names the GEM type.
UXGemGraphics* gGemGraphics;

// How many text faces the registry holds after boot: id 1 (system) + the vst_load_fonts extras.
// The toolkit font chooser reads this to list the families; drawTextFont selects one with vst_font.
i32 gGemFontCount;

class UXGemDriver : Object<UXViewDriver>
    {
    void init(void)
        {
        }

    // The neutral w,h is the CONTENT size, but wind_create/wind_open take the FULL (bordered) rect,
    // so grow it via wind_calc — otherwise the title bar eats into the content and the bottom is
    // clipped (the Corner button vanished).  kind is the chrome the driver uses everywhere.
    i32 gemKind(void)
        {
        return W_NAME | W_CLOSER | W_MOVER | W_SIZER | W_FULLER;
        }
    void gemBorderRect(i32 x, i32 y, i32 w, i32 h, i32* ox, i32* oy, i32* ow, i32* oh)
        {
        wind_calc((i32)WC_BORDER, self.gemKind(), x, y, w, h, ox, oy, ow, oh);
        }
    i32 windowCreate(i32 x, i32 y, i32 w, i32 h)
        {
        i32 fx = (i32)0;
        i32 fy = (i32)0;
        i32 fw = (i32)0;
        i32 fh = (i32)0;
        self.gemBorderRect(x, y, w, h, &fx, &fy, &fw, &fh);
        i32 handle = wind_create(self.gemKind(), fx, fy, fw, fh);
        gGemNativeLive = gGemNativeLive + (i32)1;
        return handle;
        }

    void windowSetContent(i32 handle, pointer fn, pointer ud)
        {
        wind_content(handle, fn, ud);
        }

    void windowOpen(i32 handle, i32 x, i32 y, i32 w, i32 h)
        {
        i32 fx = (i32)0;
        i32 fy = (i32)0;
        i32 fw = (i32)0;
        i32 fh = (i32)0;
        self.gemBorderRect(x, y, w, h, &fx, &fy, &fw, &fh);
        wind_open(handle, fx, fy, fw, fh);
        }

    void windowDestroy(i32 handle)
        {
        wind_close(handle);
        wind_delete(handle);
        gGemNativeLive = gGemNativeLive - (i32)1;
        }

    // ---- chrome (§11) --------------------------------------------------------
    // GEM's WF_* pointer fields take the classic 16-bit-era hi/lo split, so an m68k app
    // binds directly.  That pack is ugly and it is buried HERE, once — the toolkit above
    // says windowSetTitle(h, "Rocks") and never sees it.
    // GEM carries a string pointer to gemd as two ints (a,b) reconstructed by WIND_PTR.  The pack
    // is pointer-width dependent, exactly as libGEM's aes.h: 32-bit halves on a 64-bit build
    // (a=hi32, b=lo32), the classic 16-bit hi/lo on a 32-bit one.  Getting this wrong truncates the
    // pointer and gemd measures/draws garbage (a crash on 64-bit).
    void windowSetField(i32 handle, i32 field, u8* s)
        {
        pointer sp = (pointer)s;
        if (sizeof(pointer) == (u32)8)
            {
            i32* half = (i32*)&sp; // little-endian: [0]=low 32, [1]=high 32
            wind_set(handle, field, half[1], half[0], (i32)0, (i32)0);
            }
        else
            {
            u32 p = (u32)s;
            wind_set(handle, field, (i32)((p >> (u32)16) & (u32)$FFFF),
                     (i32)(p & (u32)$FFFF), (i32)0, (i32)0);
            }
        }
    void windowSetTitle(i32 handle, u8* s)
        {
        self.windowSetField(handle, (i32)WF_NAME, s);
        }
    void windowSetSubtitle(i32 handle, u8* s)
        {
        self.windowSetField(handle, (i32)WF_SUBTITLE, s);
        }
    void windowSetInfo(i32 handle, u8* s)
        {
        self.windowSetField(handle, (i32)WF_INFO, s);
        }
    void windowSetIcon(i32 handle, u8* slice)
        {
        self.windowSetField(handle, (i32)WF_ICON, slice);
        }
    void windowSetModified(i32 handle, bool m)
        {
        wind_set(handle, (i32)WF_TITLEFLAGS, m ? (i32)WT_MODIFIED : (i32)0, (i32)0, (i32)0, (i32)0);
        }

    // ---- scrolling -----------------------------------------------------------
    void windowContentSize(i32 handle, i32 w, i32 h)
        {
        wind_content_size(handle, w, h);
        }
    i32 windowScrollX(i32 handle)
        {
        return wind_scroll_x(handle);
        }
    i32 windowScrollY(i32 handle)
        {
        return wind_scroll_y(handle);
        }
    void windowSetScroll(i32 handle, i32 x, i32 y)
        {
        wind_set_scroll(handle, x, y);
        }
    // the AES work area
    void windowContentGeometry(i32 handle, i32* w, i32* h)
        {
        i32 x = (i32)0;
        i32 y = (i32)0;
        i32 ww = (i32)0;
        i32 hh = (i32)0;
        wind_get(handle, (i32)WF_WORKXYWH, &x, &y, &ww, &hh);
        w[0] = ww;
        h[0] = hh;
        }

    // ---- repaint -------------------------------------------------------------
    void windowInvalidate(i32 handle)
        {
        wind_redraw_win(handle);
        }
    // Redraw the dirty rect in THIS window only.  wind_redraw_area is a screen rect the client applies
    // to EVERY surface (so a second window would repaint the same local rect too — visible cross-window
    // redraw); wind_redraw_rect is per-handle, and the rect is already in the content callback's space.
    void windowInvalidateRect(i32 handle, i32 x, i32 y, i32 w, i32 h)
        {
        wind_redraw_rect(handle, x, y, w, h);
        }
    // raise to top
    void windowOrderFront(i32 handle)
        {
        wind_set(handle, (i32)WF_TOP, (i32)0, (i32)0, (i32)0, (i32)0);
        }
    // GEM: toolkit-drawn panel
    bool hasNativeFileOpen(void)
        {
        return false;
        }
    // GEM: toolkit wheel/sliders
    bool hasNativeColorPicker(void)
        {
        return false;
        }
    i32 pickColor(i32 r, i32 g, i32 b, i32* outR, i32* outG, i32* outB)
        {
        return (i32)0;
        }
    // GEM: toolkit font chooser
    bool hasNativeFontPicker(void)
        {
        return false;
        }
    i32 pickFont(u8* inF, i32 inS, i32 inB, i32 inI, u8* outF, i32 cap, i32* outS, i32* outB, i32* outI)
        {
        return (i32)0;
        }
    i32 nowMs(void)
        {
        return xg_now_ms();
        }
    void nowUTC(i32* out7)
        {
        xg_now_utc(out7);
        }
    i32 localOffsetMinutes(void)
        {
        return xg_local_offset_minutes();
        }

    // Settings live in the SYSTEM REGISTRY — the same SQLite database (/OS/var/registry.db) the
    // desktop keeps its own preferences in, through registry.c's thin API.  No SQL up here.
    // GEM scrolls in the toolkit (scrollsNatively is false): the AES has no scroll container of its
    // own for this, UXScrollView moves the document node itself, and its own offset is the truth.
    void nativeScrollTo(pointer h, i32 node, i32 px)
        {
        }
    i32 nativeScrollPx(pointer h, i32 node)
        {
        return (i32)0;
        }

    bool settingGet(u8* domain, u8* key, u8* out, i32 cap)
        {
        return xg_setting_get(domain == (u8*)0 ? (u8*)"" : domain, key, out, cap) != (i32)0;
        }
    bool settingSet(u8* domain, u8* key, u8* value)
        {
        return xg_setting_set(domain == (u8*)0 ? (u8*)"" : domain, key, value) != (i32)0;
        }
    bool settingRemove(u8* domain, u8* key)
        {
        return xg_setting_remove(domain == (u8*)0 ? (u8*)"" : domain, key) != (i32)0;
        }

    // The VDI's own measurement, at the size the text will be drawn: set the height, ask for the
    // extent, and read the box's width.  vst_height is sticky workstation state, so put it back.
    i32 textWidth(u8* s, i32 size)
        {
        i32 h = aes_handle(); // the AES's workstation (the driver keeps no vh)
        i16 ext[8];
        vst_height(h, size > (i32)0 ? size : (i32)16, (pointer)0, (pointer)0, (pointer)0, (pointer)0);
        vqt_extent(h, s, (pointer)&ext[(i32)0]);
        i32 w = (i32)ext[(i32)2] - (i32)ext[(i32)0];
        vst_height(h, (i32)16, (pointer)0, (pointer)0, (pointer)0, (pointer)0); // sticky ws state
        return w > (i32)0 ? w : (i32)0;
        }

    // Styled measurement: select the face, synthesise the effects, size it, ask, then put the
    // workstation back exactly as drawTextFont does — these are sticky ws state.
    i32 textWidthStyled(u8* s, u8* family, i32 size, bool bold, bool italic)
        {
        i32 h = aes_handle();
        i16 ext[8];
        vst_font(h, gGemGraphics != (UXGemGraphics*)0 ? gGemGraphics.fontIdFor(family) : (i32)1);
        i32 fx = (i32)0;
        if (bold)
            {
            fx = fx | (i32)1;
            }
        if (italic)
            {
            fx = fx | (i32)4;
            }
        vst_effects(h, fx);
        vst_height(h, size > (i32)0 ? size : (i32)16, (pointer)0, (pointer)0, (pointer)0, (pointer)0);
        vqt_extent(h, s, (pointer)&ext[(i32)0]);
        i32 w = (i32)ext[(i32)2] - (i32)ext[(i32)0];
        vst_effects(h, (i32)0);
        vst_font(h, (i32)1);
        vst_height(h, (i32)16, (pointer)0, (pointer)0, (pointer)0, (pointer)0);
        return w > (i32)0 ? w : (i32)0;
        }

    // GEM has no native popup control (UXKindPopup falls through to the toolkit's own drawRect), and it
    // cannot borrow the AES's menu_popup either: that places its panel in SCREEN coordinates by opening a
    // panel WINDOW, and in the gemd split neither half of that is available to a client.  A client's work
    // area IS its surface and starts at 0,0 (aes/window.c says so explicitly — "no chrome model on the
    // client side"), so it cannot know where its window sits; and asking gemd for a menu-panel window
    // makes gemd drop the app's OWN menu instead.  Driving it from here opened the Windows menu.
    //
    i32 runPopupMenu(pointer peer, i32 x, i32 y)
        {
        UXPopUpButton* p = (UXPopUpButton* ?)peer;
        if (p == (UXPopUpButton*)0)
            {
            return (i32)-1;
            }
        i32 n = p.nativeItemCount();
        if (n <= (i32)0)
            {
            return (i32)-1;
            }
        // a menu panel, not a list view
        if (n > (i32)24)
            {
            n = (i32)24;
            }
        menu_item rows[24];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            rows[i].label = (pointer)p.nativeItemTitle(i);
            rows[i].accel = (pointer)0;
            rows[i].id = i;
            rows[i].sub = (pointer)0;
            rows[i].nsub = (i32)0;
            rows[i].flags = (u32)0;
            }
        // Window-local -> SCREEN, which is what menu_popup places at.  NOT via WF_WORKXYWH: that is
        // defined to answer 0,0 for a client (its work area IS its surface — aes/window.c), which put the
        // panel at the top-left of the desktop.  WF_CURRXYWH does carry the window's real screen rect
        // (gemd maintains it through wind_open and every GEM_MSG_MOVED), and wind_calc converts that
        // bordered rect to the work origin the view tree is relative to — the same call windowCreate
        // already uses in the other direction.
        i32 cx = (i32)0;
        i32 cy = (i32)0;
        i32 cw = (i32)0;
        i32 chh = (i32)0;
        wind_get(aes_event_win(), (i32)WF_CURRXYWH, &cx, &cy, &cw, &chh);
        i32 wx = (i32)0;
        i32 wy = (i32)0;
        i32 ww = (i32)0;
        i32 wh = (i32)0;
        wind_calc((i32)WC_WORK, self.gemKind(), cx, cy, cw, chh, &wx, &wy, &ww, &wh);
        return menu_popup((pointer)&rows[(i32)0], n, wx + x, wy + y);
        }
    // Enumerate the loaded faces so the toolkit chooser can list real families (id 1 = system, 2..N = files).
    i32 fontFamilyCount(void)
        {
        return gGemFontCount;
        }
    i32 fontFamilyName(i32 idx, u8* out, i32 cap)
        {
        if (idx < (i32)0 || idx >= gGemFontCount)
            {
            return (i32)-1;
            }
        u8* nm = vdi_font_name(idx + (i32)1); // idx 0 -> id 1 (system)
        i32 i = (i32)0;
        while (nm[i] != (u8)0 && i < cap - (i32)1)
            {
            out[i] = nm[i];
            i = i + (i32)1;
            }
        out[i] = (u8)0;
        return i;
        }
    // (never called — see above)
    i32 fileOpen(u8* prompt, u8* startDir, u8* out, i32 outCap)
        {
        return (i32)0;
        }
    i32 listDir(u8* path, u8* out, i32 outCap)
        {
        return xg_listdir(path, out, outCap);
        }
    i32 fileDelete(u8* path)
        {
        return xg_unlink(path);
        }
    i32 fileRename(u8* src, u8* dst)
        {
        return xg_rename(src, dst);
        }
    i32 fileCopy(u8* src, u8* dst)
        {
        return xg_copyfile(src, dst);
        }

    // ---- structure (§6) ------------------------------------------------------
    // The AES does the hard parts: objc_offset walks the parent links, objc_find hit-tests.
    // The toolkit writes neither.
    void treeOffset(pointer tree, i32 obj, i32* ax, i32* ay)
        {
        objc_offset(tree, obj, ax, ay);
        }
    i32 treeHitTest(pointer tree, i32 start, i32 x, i32 y)
        {
        return objc_find(tree, start, (i32)UX_DEPTH, x, y);
        }
    // The absolute frame of an object: the AES walks the parent links for x,y; the size is
    // the object's own.  (So the neutral layer never reads an ob_ field to build a rect.)
    void structAbsFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        i32 ax = (i32)0;
        i32 ay = (i32)0;
        objc_offset((pointer)t, i, &ax, &ay);
        x[0] = ax;
        y[0] = ay;
        w[0] = (i32)t[i].ob_w;
        ht[0] = (i32)t[i].ob_h;
        }

    // ---- the OBJECT[] itself (driver-owned; UXViewTree holds only the handle) -------------
    pointer structNew(void)
        {
        UXGemTree* s = (UXGemTree*)malloc((u32)sizeof(UXGemTree));
        s.cap = (i32)16;
        s.count = (i32)0;
        s.owns = (i32)1;
        s.tree = (OBJECT*)malloc((u32)s.cap * (u32)sizeof(OBJECT));
        return (pointer)s;
        }
    void structFree(pointer h)
        {
        if (h == (pointer)0)
            {
            return;
            }
        UXGemTree* s = (UXGemTree*)h;
        if (s.owns != (i32)0 && s.tree != (OBJECT*)0)
            {
            free((pointer)s.tree);
            }
        free(h);
        }
    // Adopt an OBJECT[] somebody else owns (a tree straight out of a .rsc) — nothing copied.
    void structAdopt(pointer h, pointer t, i32 n)
        {
        UXGemTree* s = (UXGemTree*)h;
        if (s.owns != (i32)0 && s.tree != (OBJECT*)0)
            {
            free((pointer)s.tree);
            }
        s.tree = (OBJECT*)t;
        s.owns = (i32)0;
        s.count = n;
        s.cap = n;
        }
    // for the draw seam
    pointer structObjects(pointer h)
        {
        return (pointer)((UXGemTree*)h).tree;
        }
    i32 structLength(pointer h)
        {
        return ((UXGemTree*)h).count;
        }

    // Grow the flat array, preserving indices (every ob_next/head/tail stays valid).  Private.
    void structGrow(pointer h, i32 want)
        {
        UXGemTree* s = (UXGemTree*)h;
        if (want <= s.cap)
            {
            return;
            }
        i32 cap = s.cap;
        while (cap < want)
            {
            cap = cap * (i32)2;
            }
        s.tree = (OBJECT*)realloc((pointer)s.tree, (u32)cap * (u32)sizeof(OBJECT));
        s.cap = cap;
        }
    // Map a neutral kind to a GEM object type.
    i32 gemTypeOf(i32 kind)
        {
        if (kind == (i32)UXKindBox)
            {
            return (i32)G_BOX;
            }
        // GEM paints the table background
        if (kind == (i32)UXKindTable)
            {
            return (i32)G_BOX;
            }
        if (kind == (i32)UXKindButton)
            {
            return (i32)G_BUTTON;
            }
        if (kind == (i32)UXKindField)
            {
            return (i32)G_FTEXT;
            }
        if (kind == (i32)UXKindLabel)
            {
            return (i32)G_STRING;
            }
        // UXKindView and UXKindShield: app-drawn.  A shield needs nothing more on
        // GEM -- nothing here is a native widget that could swallow a press, so
        // the toolkit's own hit-test already reaches whatever is on top, which is
        // the behaviour the shield exists to restore on the other backends.
        return (i32)G_USERDEF;
        }
    // Append a raw slot; returns the new index.
    i32 structAppend(pointer h, i32 kind, i32 x, i32 y, i32 w, i32 ht)
        {
        UXGemTree* s = (UXGemTree*)h;
        self.structGrow(h, s.count + (i32)1);
        i32 i = s.count;
        OBJECT* t = s.tree;
        t[i].ob_next = (i16)-1;
        t[i].ob_head = (i16)-1;
        t[i].ob_tail = (i16)-1;
        t[i].ob_type = (u16)self.gemTypeOf(kind);
        t[i].ob_flags = (u16)0;
        t[i].ob_state = (u16)0;
        t[i].ob_spec = (pointer)0;
        t[i].ob_x = (i16)x;
        t[i].ob_y = (i16)y;
        t[i].ob_w = (i16)w;
        t[i].ob_h = (i16)ht;
        s.count = i + (i32)1;
        return i;
        }
    // objc_add: link `child` as the LAST child of `parent`.
    void structAddChild(pointer h, i32 parent, i32 child)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        t[child].ob_next = (i16)parent; // last child points BACK at the parent
        if (t[parent].ob_head == (i16)-1)
            {
            t[parent].ob_head = (i16)child;
            }
        else
            {
            i16 last = t[parent].ob_tail;
            t[last].ob_next = (i16)child;
            }
        t[parent].ob_tail = (i16)child;
        }
    // objc_delete: unlink `child`, leaving the slot in place.
    void structRemoveChild(pointer h, i32 parent, i32 child)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        i16 hd = t[parent].ob_head;
        if (hd == (i16)-1)
            {
            return;
            }
        if (hd == (i16)child)
            {
            if (t[parent].ob_tail == (i16)child)
                {
                t[parent].ob_head = (i16)-1;
                t[parent].ob_tail = (i16)-1;
                }
            else
                {
                t[parent].ob_head = t[child].ob_next;
                }
            }
        else
            {
            i16 p = hd;
            while (p != (i16)-1 && t[p].ob_next != (i16)child)
                {
                p = t[p].ob_next;
                }
            if (p == (i16)-1)
                {
                return;
                }
            t[p].ob_next = t[child].ob_next;
            if (t[parent].ob_tail == (i16)child)
                {
                t[parent].ob_tail = p;
                }
            }
        t[child].ob_next = (i16)-1;
        }
    // The AES needs OF_LASTOB ($0020) on the final object of the tree.
    void structFinalise(pointer h)
        {
        UXGemTree* s = (UXGemTree*)h;
        if (s.count == (i32)0)
            {
            return;
            }
        OBJECT* t = s.tree;
        for (i32 i = (i32)0; i < s.count; i = i + (i32)1)
            {
            t[i].ob_flags = t[i].ob_flags & (u16)$FFDF;
            }
        t[s.count - (i32)1].ob_flags = t[s.count - (i32)1].ob_flags | (u16)$0020;
        }

    // ---- per-object geometry + state (the OBJECT fields are the driver's) ----------------
    void structSetFrame(pointer h, i32 i, i32 x, i32 y, i32 w, i32 ht)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        t[i].ob_x = (i16)x;
        t[i].ob_y = (i16)y;
        t[i].ob_w = (i16)w;
        t[i].ob_h = (i16)ht;
        }
    void structFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        x[0] = (i32)t[i].ob_x;
        y[0] = (i32)t[i].ob_y;
        w[0] = (i32)t[i].ob_w;
        ht[0] = (i32)t[i].ob_h;
        }
    void structSetHidden(pointer h, i32 i, i32 on)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        if (on != (i32)0)
            {
            t[i].ob_flags = t[i].ob_flags | (u16)OF_HIDETREE;
            }
        else
            {
            t[i].ob_flags = t[i].ob_flags & (u16)$FF7F;
            }
        }
    i32 structIsHidden(pointer h, i32 i)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        return (t[i].ob_flags & (u16)OF_HIDETREE) != (u16)0 ? (i32)1 : (i32)0;
        }
    void structSetEnabled(pointer h, i32 i, i32 on)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        // clear OS_DISABLED
        if (on != (i32)0)
            {
            t[i].ob_state = t[i].ob_state & (u16)$FFF7;
            }
        else
            {
            t[i].ob_state = t[i].ob_state | (u16)OS_DISABLED;
            }
        }
    i32 structIsEnabled(pointer h, i32 i)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        return (t[i].ob_state & (u16)OS_DISABLED) == (u16)0 ? (i32)1 : (i32)0;
        }
    void structSetSelected(pointer h, i32 i, i32 on)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        if (on != (i32)0)
            {
            t[i].ob_state = t[i].ob_state | (u16)OS_SELECTED;
            }
        else
            {
            t[i].ob_state = t[i].ob_state & (u16)$FFFE;
            }
        }
    i32 structIsSelected(pointer h, i32 i)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        return (t[i].ob_state & (u16)OS_SELECTED) != (u16)0 ? (i32)1 : (i32)0;
        }
    void structSetClips(pointer h, i32 i, i32 on)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        if (on != (i32)0)
            {
            t[i].ob_flags = t[i].ob_flags | (u16)OF_CLIPCHILDREN;
            }
        else
            {
            t[i].ob_flags = t[i].ob_flags & (u16)$EFFF;
            }
        }

    // ---- control realization (an object's content + kind flags) --------------------------
    // On GEM the ob_spec IS the content: a button's label string, a field's TEDINFO, a cell's
    // text.  Selectable/editable are the AES flags the edit engine + click tracker read.
    void structSetSpec(pointer h, i32 i, pointer spec)
        {
        ((UXGemTree*)h).tree[i].ob_spec = spec;
        }
    // GEM renders the table from its subtree
    void structSetPeer(pointer h, i32 i, pointer peer)
        {
        }
    // GEM forms are fixed layouts
    void structSetAutoresize(pointer h, i32 i, i32 mask)
        {
        }
    // the neutral layer lays GEM out
    bool driverAutoresizes(void)
        {
        return false;
        }
    void structSetSelectable(pointer h, i32 i, i32 on)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        if (on != (i32)0)
            {
            t[i].ob_flags = t[i].ob_flags | (u16)OF_SELECTABLE;
            }
        else
            {
            t[i].ob_flags = t[i].ob_flags & (u16)$FFFE;
            }
        }
    void structSetEditable(pointer h, i32 i, i32 on)
        {
        OBJECT* t = ((UXGemTree*)h).tree;
        if (on != (i32)0)
            {
            t[i].ob_flags = t[i].ob_flags | (u16)OF_EDITABLE;
            }
        else
            {
            t[i].ob_flags = t[i].ob_flags & (u16)$FFF7;
            }
        }

    // ---- painting (§7) -------------------------------------------------------
    // objc_draw walks the OBJECT tree; for each G_USERDEF it calls back through the
    // userdraw hook (registered here), which is UXWindow's drawRect seam.
    void treeSetUserDraw(pointer fn, pointer ud)
        {
        objc_set_userdraw(fn, ud);
        }
    // GEM draws its controls; no native widgets
    void realizeTree(i32 handle, pointer tree)
        {
        }
    void treeDraw(pointer tree, i32 start, i32 clx, i32 cly, i32 clw, i32 clh)
        {
        objc_draw(tree, start, (i32)UX_DEPTH, clx, cly, clw, clh);
        }
    // Bind the driver's context to the view at `abs` and hand it back as UXGraphics — this is
    // what the draw seam calls per custom view, so it never touches the VDI handle or theme.
    UXGraphics* beginViewDraw(i32 ax, i32 ay, i32 aw, i32 ah)
        {
        gGemGraphics.bind(aes_handle(), (pointer)&gGemTheme,
                          UXGeom.make((i16)ax, (i16)ay, (i16)aw, (i16)ah));
        return gGemGraphics;
        }
    // GEM draws scroll content inline; no sub-surface
    void setDrawOffset(i32 x, i32 y)
        {
        }
    // GEM moves the document itself
    bool scrollsNatively(void)
        {
        return false;
        }

    // ---- text editing --------------------------------------------------------
    // A field editor bound to the app's text buffer.  On GEM it is a TEDINFO — the thing the
    // edit engine operates and the field's ob_spec points at.  A host driver would return its
    // own editor handle (or the buffer itself for a native EDIT/NSTextField).  calloc so the
    // TEDINFO fields the toolkit does not set start zero, as the AES expects.
    pointer fieldEditorNew(u8* buf, i32 cap)
        {
        TEDINFO* ed = (TEDINFO*)calloc((u32)1, (u32)sizeof(TEDINFO));
        ed.te_ptext = buf;
        ed.te_ptmplt = (u8*)0; // free text: no template
        ed.te_pvalid = (u8*)0; // no validation (see fieldEditorSetValid)
        ed.te_just = (i16)TE_LEFT;
        ed.te_txtlen = (i16)cap;
        return (pointer)ed;
        }
    void fieldEditorSetValid(pointer ed, u8* valid)
        {
        ((TEDINFO*)ed).te_pvalid = valid;
        }
    // The AES G_FTEXT has no cue-banner concept (a template is interleaved, not a disappearing
    // prompt), so a placeholder is a no-op on GEM — the field simply starts empty.
    void fieldEditorSetPlaceholder(pointer ed, u8* s)
        {
        }
    // The AES field editor (objc_edit) has no password mode, so masking is a no-op on GEM — the
    // field shows plain text.  A masked GEM field would need AES-side work in the gem repo.
    void fieldEditorSetSecure(pointer ed, i32 on)
        {
        }
    void fieldEditorFree(pointer ed)
        {
        free(ed);
        }

    i32 editText(pointer tree, i32 obj, i32 key, i32* caret, i32 mode)
        {
        i32 em = (i32)ED_CHAR; // UXEditKey
        if (mode == (i32)UXEditBegin)
            {
            em = (i32)ED_INIT;
            }
        else if (mode == (i32)UXEditEnd)
            {
            em = (i32)ED_END;
            }
        return objc_edit(tree, obj, key, caret, em);
        }

    // ---- menus ---------------------------------------------------------------
    // GEM builds the tree, draws the bar, tracks the pull-down and intercepts the click
    // inside evnt_multi.  The toolkit writes none of it — it hands over a model.
    pointer menuBuild(pointer defs, i32 n, i32 screenW)
        {
        UXMenuDef* src = (UXMenuDef*)defs;                                     // neutral, 20-byte stride on 64-bit
        GemMenuDef* c = (GemMenuDef*)malloc((u32)n * (u32)sizeof(GemMenuDef)); // C stride
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            c[i].title = (pointer)src[i].title;
            c[i].items = (pointer)src[i].items;
            c[i].nitems = (pointer)src[i].nitems; // int in the low bytes; C reads int*2*ptr
            }
        return menu_build((pointer)c, n, screenW);
        }
    void menuShow(pointer menu, i32 show)
        {
        menu_bar(menu, show);
        }
    i32 menuItemOrd(pointer menu, i32 titleOrd, i32 itemObj)
        {
        return menu_item_ord(menu, titleOrd, itemObj);
        }
    void menuCheck(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
        {
        menu_icheck(menu, titleOrd, itemOrd, on);
        }
    void menuEnable(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
        {
        menu_ienable(menu, titleOrd, itemOrd, on);
        }

    // A GEM alert is a STRING: "[icon][line|line][button|button]".  form_alert builds, centres,
    // saves-under, runs the modal loop, restores, and returns the 1-based button.  The neutral
    // model comes in as pieces; the GEM string format lives here, not in UXAlert.
    i32 alertRun(i32 icon, u8* lines, u8* buttons, i32 defaultBtn)
        {
        u8 digit[2];
        digit[0] = (u8)(48 + icon);
        digit[1] = (u8)0;
        u8* s = UXStr.cat("[", (u8)0, &digit[0]);
        s = UXStr.cat(s, (u8)0, "][");
        s = UXStr.cat(s, (u8)0, lines);
        s = UXStr.cat(s, (u8)0, "][");
        s = UXStr.cat(s, (u8)0, buttons);
        s = UXStr.cat(s, (u8)0, "]");
        return form_alert(defaultBtn, s);
        }

    // ---- events --------------------------------------------------------------
    // The AES intercepts menu-bar and window-frame interaction inside evnt_multi before the
    // client sees anything, so what returns is only what the app must handle.  We decode the
    // raw GEM message/mouse/key into a neutral UXEvent, so the run loop names no GEM constant.
    void gemPump(i32 classes, i32 timeoutMs, UXEvent* ev)
        {
        i16 msg[8];
        i32 mx = (i32)0;
        i32 my = (i32)0;
        i32 mb = (i32)0;
        i32 ks = (i32)0;
        i32 key = (i32)0;
        i32 nc = (i32)0;
#ifdef ARCH_arm64
        // evnt_multi has 23 args; xtc's arm64 backend mis-marshals everything past the 8th, so its
        // output pointers come back garbage on macOS.  Route through the libxtos wrapper, whose 4
        // register args xtc passes correctly and which makes the wide call C-side.        i32 out[6];
        i32 what = xg_evnt_multi(classes, (pointer)&msg[0], timeoutMs, (pointer)&out[0]);
        mx = out[0];
        my = out[1];
        mb = out[2];
        ks = out[3];
        key = out[4];
        nc = out[5];
#else
        i32 what = evnt_multi(classes, (i32)1, (i32)1, (i32)1,
                              (i32)0, (i32)0, (i32)0, (i32)0, (i32)0,
                              (i32)0, (i32)0, (i32)0, (i32)0, (i32)0,
                              (pointer)&msg[0], timeoutMs, (i32)0,
                              (pointer)&mx, (pointer)&my, (pointer)&mb,
                              (pointer)&ks, (pointer)&key, (pointer)&nc);
#endif
        ev.kind = (u8)UXEventNone;
        ev.handle = (i32)0; // clear per event: a mouse-down routes by screen point, not handle
        if ((what & MU_MESAG) != (i32)0)
            {
            i16 k = msg[0];
            if (k == (i16)MN_SELECTED)
                {
                ev.kind = (u8)UXEventMenuSelect;
                ev.a = (i32)msg[3];
                ev.b = (i32)msg[4];
                }
            else if (k == (i16)WM_CLOSED)
                {
                ev.kind = (u8)UXEventClose;
                ev.handle = (i32)msg[3];
                }
            else if (k == (i16)WM_REDRAW)
                {
                ev.kind = (u8)UXEventRedraw;
                ev.handle = (i32)msg[3];
                }
            else if (k == (i16)WM_SIZED)
                {
                ev.kind = (u8)UXEventResize;
                ev.handle = (i32)msg[3];
                }
            else if (k == (i16)WM_MOVED)
                {
                ev.kind = (u8)UXEventMove;
                ev.handle = (i32)msg[3];
                }
            else if (k == (i16)WM_WHEEL)
                {
                ev.kind = (u8)UXEventWheel;
                ev.handle = (i32)msg[3];
                ev.x = (i16)msg[4];
                ev.y = (i16)msg[5];
                ev.a = (i32)msg[6];
                }
            return;
            }
        if ((what & MU_BUTTON) != (i32)0)
            {
            ev.kind = (u8)UXEventMouseDown;
            ev.x = (i16)mx;
            ev.y = (i16)my;
            ev.buttons = (u16)mb;
            ev.modifiers = (u16)ks; // shift/ctrl on a click — a table reads it for multi-select
            return;
            }
        if ((what & MU_KEYBD) != (i32)0)
            {
            ev.kind = (u8)UXEventKeyDown;
            ev.key = (u16)key;
            ev.modifiers = (u16)ks;
            return;
            }
        }
    // The run loop: block for the next input or window message.
    void nextEvent(i32 timeoutMs, UXEvent* ev)
        {
        self.gemPump(MU_KEYBD | MU_BUTTON | MU_MESAG, timeoutMs, ev);
        }
    // Drain pending window messages without consuming input (async gemd state sync).
    void pumpMessages(i32 timeoutMs, UXEvent* ev)
        {
        self.gemPump(MU_MESAG | MU_TIMER, timeoutMs, ev);
        }

    // The neutral run loop passes the event's coordinates, but GEM input is WINDOW-LOCAL (gemd
    // localises it before forwarding) and already tagged with its window — so wind_find(x,y), which
    // wants SCREEN coordinates, is the wrong lookup (it misses whenever the work origin isn't 0,0).
    // Return the window gemd delivered the event to, exactly as AppKit/Win32 return their one window.
    i32 windowAtPoint(i32 x, i32 y)
        {
        return aes_event_win();
        }

    // One modal drag-track step: block until the pointer moves or the button releases (window-local
    // coords).  gemd forwards motion to the focused window while the button is held, so a table can
    // loop this after a press to extend its selection as the pointer sweeps rows.
    i32 trackDragStep(i32* x, i32* y)
        {
        // a replayed press must not follow the live pointer
        if (gInputReplay)
            {
            return (i32)0;
            }
#ifdef ARCH_arm64
        return xg_drag_next(x, y);
#else
        i32 mx = (i32)0;
        i32 my = (i32)0;
        i32 mb = (i32)0;
        i32 ks = (i32)0;
        i32 key = (i32)0;
        i32 nc = (i32)0;
        // MU_BUTTON|MU_M1, bstate 0 (fire on release), a zero rect + m1f=1 (fire on any motion).
        i32 r = evnt_multi((i32)(MU_BUTTON | MU_M1), (i32)1, (i32)1, (i32)0,
                           (i32)1, (i32)0, (i32)0, (i32)0, (i32)0,
                           (i32)0, (i32)0, (i32)0, (i32)0, (i32)0,
                           (pointer)0, (i32)0, (i32)0,
                           (pointer)&mx, (pointer)&my, (pointer)&mb,
                           (pointer)&ks, (pointer)&key, (pointer)&nc);
        x[0] = mx;
        y[0] = my;
        return (r & (i32)MU_BUTTON) != (i32)0 ? (i32)0 : (i32)1;
#endif
        }

    // ---- boot ----------------------------------------------------------------
    // The ~20 lines every C GEM app copy-pastes: get the framebuffer + back buffer, open a
    // VDI workstation on the back buffer, load the theme, init the AES.  A host driver does
    // its own native bring-up here instead.  (This is the SERVER path — it initialises the
    // AES, so this process IS the window system today; once the AES server lands it becomes a
    // connect/attach, and nothing above the driver changes.)
    bool boot(i32* screenW, i32* screenH)
        {
        os_fbinfo fb;
        os_fbinfo wp;
        if (sys_fb_info((pointer)&fb) != (i32)0)
            {
            return false;
            }
        if (sys_fb_wallpaper((pointer)&wp) != (i32)0)
            {
            return false;
            }

        gGemBackBuffer.w = (i32)wp.w;
        gGemBackBuffer.h = (i32)wp.h;
        gGemBackBuffer.stride = (i32)wp.stride;
        gGemBackBuffer.px = (u32*)wp.addr;

        pointer face = font_face_open("/System/fonts/AovelSansRounded.ttf");
        if (face == (pointer)0)
            {
            return false;
            }

        vdi_init((pointer)&gGemBackBuffer); // the VDI keeps this pointer — see above
        i32 vh = v_opnvwk((pointer)&gGemBackBuffer);
        vdi_set_face(face);

        if (theme_load((pointer)&gGemTheme, "/System/themes/Aristo2/1x") != (i32)0)
            {
            return false;
            }
        aes_init(vh, (pointer)&gGemTheme);
        appl_init();
        // Map the font directory (redirected to gem/fonts) so the toolkit font chooser has real families
        // to select with vst_font: id 1 = the system face, 2..N = the .ttf files there.
        vdi_set_font_dir((u8*)"/OS/fonts");
        gGemFontCount = (i32)1 + vst_load_fonts(vh, (i32)0);
        wind_set_desktop($20304080);
        gGemGraphics = new UXGemGraphics(); // the context the draw seam reuses

        // Xtg drives every repaint through its own damage/display cycle (where the draw surface
        // is bound during ux_window_draw).  The AES's objc_edit would otherwise redraw the field
        // IMMEDIATELY — straight from becomeFirstResponder/keyDown, outside any paint, blitting to
        // an unbound back buffer (a crash when a field is focused before the first paint).  Tell
        // the edit engine to update state only; the caret/text land on Xtg's next paint (the field
        // already calls setNeedsDisplay).  COMPILER-THREAD #7.
        objc_edit_set_nodraw((i32)1);

        screenW[0] = (i32)fb.w;
        screenH[0] = (i32)fb.h;
        return true;
        }

    i32 liveNativeCount(void)
        {
        return gGemNativeLive;
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
