// UXGtkDriver.xc — the GTK4 realization of UXViewDriver: the Linux-desktop
// backend (plan phase 1b), AppKit's sibling by the same pattern the iOS
// driver just proved: the shared shadow tree, custom views painting through
// drawRect -> UXCairoGraphics -> the cairo_t of the draw in flight, and
// realizeTree overlaying REAL GtkButton/GtkCheckButton/GtkEntry/GtkScale/
// GtkSpinButton/GtkProgressBar/GtkDropDown widgets whose signals land in the
// fire/value/field seams.  Desktop loop semantics: driverOwnsRunLoop is
// FALSE — GTK's main context pumps under the neutral blocking loop
// (gtk-loop milestone wires the queue; the gate drives directly).
#import "UXViewDriver.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXCairoGraphics.xc"
#import "UXEvent.xc"
#import "UXControl.xc"
#import "UXSlider.xc"           // native UISlider overlay reads/writes this widget's value
#import "UXStepper.xc"          // native UIStepper overlay
#import "UXPopUpButton.xc"      // native UIButton+UIMenu pull-down
#import "UXSegmentedControl.xc" // native UISegmentedControl overlay
#import "UXProgressBar.xc"      // native UIProgressView overlay
#import "UXApplication.xc"      // gApp: the driver-owned loop starts the delegate, and stop() quits
#import "UXLibc.xc"

// The shim (libUXIos.m).  Primitive signatures only — no CGRect crosses into xtc.
i32 ux_gtk_boot(i32* w, i32* h);
void ux_gtk_pump(void);
void ux_gtk_wait_event(void);
i32 ux_gtk_alert(i32 parent, u8* lines, u8* buttons, i32 defBtn);
void ux_gtk_clip(i32 x, i32 y, i32 w, i32 h);
void ux_gtk_clip_end(void);
i32 ux_gtk_setting_get(u8* domain, u8* key, u8* out, i32 cap);
i32 ux_gtk_setting_set(u8* domain, u8* key, u8* value);
i32 ux_gtk_setting_remove(u8* domain, u8* key);
i32 ux_gtk_window_create(i32 x, i32 y, i32 w, i32 h);
void ux_gtk_window_set_content(i32 handle, pointer fn, pointer ud);
void ux_gtk_window_open(i32 handle, i32 x, i32 y, i32 w, i32 h);
void ux_gtk_window_set_title(i32 handle, u8* s);
void ux_gtk_window_front(i32 handle);
void ux_gtk_window_close(i32 handle);
void ux_gtk_window_invalidate(i32 handle);
void ux_gtk_content_geometry(i32 handle, i32* w, i32* h);
i32 ux_gtk_native_count(void);
i32 ux_gtk_has_control(i32 handle, i32 node);
void ux_gtk_make_button(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* title);
void ux_gtk_make_label(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* text);
void ux_gtk_set_control_frame(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h);
void ux_gtk_set_control_enabled(i32 handle, i32 node, i32 on);
void ux_gtk_set_control_hidden(i32 handle, i32 node, i32 on);
void ux_gtk_set_control_fire(pointer fn);
void ux_gtk_set_value_changed(pointer fn);
void ux_gtk_make_check(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* title, i32 on);
void ux_gtk_set_check(i32 handle, i32 node, i32 on);
void ux_gtk_make_slider(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 lo, i32 hi, i32 val);
void ux_gtk_set_slider_value(i32 handle, i32 node, i32 val);
void ux_gtk_make_stepper(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 lo, i32 hi, i32 step, i32 wraps, i32 val);
void ux_gtk_set_stepper_value(i32 handle, i32 node, i32 val);
void ux_gtk_make_progress(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 mille);
void ux_gtk_set_progress(i32 handle, i32 node, i32 mille, i32 indeterminate);
void ux_gtk_make_popup(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h);
void ux_gtk_set_field_hooks(pointer fn);
void ux_gtk_set_mouse(pointer fn); // register the pointer-event forwarder
// The input shield (UXKindShield): a bare widget above the controls, so a click on a
// design surface reaches the toolkit instead of operating the widget under it.
void ux_gtk_make_shield(i32 handle, i32 x, i32 y, i32 w, i32 h, i32 hidden);
void ux_gtk_raise_shield(i32 handle);
i32 ux_gtk_has_shield(i32 handle);
i32 ux_gtk_shield_on_top(i32 handle);
void ux_gtk_set_align(i32 handle, i32 node, i32 a); // label/entry text alignment
i32 ux_gtk_get_align(i32 handle, i32 node);         // ...and what it actually is
i32 ux_gtk_drag_next(i32* x, i32* y);               // one modal drag-track step: 1 = dragging, 0 = up
void ux_gtk_post_press(i32 handle, i32 x, i32 y);   // test seam: a headless gate has no pointer
void ux_gtk_post_motion(i32 x, i32 y);
void ux_gtk_post_release(void);
void ux_gtk_make_field(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* buf, i32 cap, i32 secure);
void ux_gtk_update_field(i32 handle, i32 node);
void ux_gtk_popup_add_item(i32 handle, i32 node, u8* title);
void ux_gtk_popup_select(i32 handle, i32 node, i32 i);
void ux_gtk_make_segmented(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 nseg);
void ux_gtk_seg_set_label(i32 handle, i32 node, i32 seg, u8* label);
void ux_gtk_seg_select(i32 handle, i32 node, i32 seg);
i32 ux_gtk_text_width(u8* s, u8* family, i32 size, i32 bold, i32 italic);
i32 ux_gtk_now_ms(void);
void ux_gtk_now_utc(i32* out7);
i32 ux_gtk_local_offset_minutes(void);

// The draw-seam callbacks (§4 rule: these signatures ARE the ABI).
typedef i32 UXGtkUserDrawFn(pointer tree, i32 obj, pointer ud);

// ── the shadow tree (the shared shape: Win32/AppKit/web) ────────────────────
struct GKNode
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
    } struct GKTree
    {
    GKNode* nodes;
    i32 count;
    i32 cap;
    i32 win;
    }

    struct GKField
    {
    u8* buf;
    i32 cap;
    u8* valid;
    u8* place;
    i32 secure;
    }

    // ── driver state ────────────────────────────────────────────────────────────
    UXCairoGraphics* gGtkGfx;
i32 gGtkDrawOX;
i32 gGtkDrawOY;
pointer gGtkUserFn;
pointer gGtkUserUd;
GKTree* gGtkDrawTree;

// A native control was tapped: fire its neutral widget's action directly, by
// (handle, node) — the mac driver's fire-by-peer pattern, verbatim.
pointer gGtkCtlPeer[16384]; // [handle*256 + node] -> the control's neutral widget
UXEvent* gGtkClickEvent;
// A native value control moved: adopt the number into the peer, fire its
// action — the mac driver's xgAKValueChanged, iOS edition (the UISwitch case
// is new: its 0/1 lands in the peer UXCheckbox before the fire).
void uxGtkValueChanged(i32 handle, i32 node, i32 value)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)256)
        {
        return;
        }
    UXControl* ctl = (UXControl* ?)gGtkCtlPeer[handle * (i32)256 + node];
    if (ctl == (UXControl*)0)
        {
        return;
        }
    UXCheckbox* cb = (UXCheckbox* ?)ctl;
    if (cb != (UXCheckbox*)0)
        {
        cb.setChecked(value != (i32)0);
        }
    UXSlider* sl = (UXSlider* ?)ctl;
    if (sl != (UXSlider*)0)
        {
        sl.applyNativeValue(value);
        }
    UXStepper* stp = (UXStepper* ?)ctl;
    if (stp != (UXStepper*)0)
        {
        stp.applyNativeValue(value);
        }
    UXPopUpButton* pu = (UXPopUpButton* ?)ctl;
    if (pu != (UXPopUpButton*)0)
        {
        pu.applyNativeSelection(value);
        }
    UXSegmentedControl* seg = (UXSegmentedControl* ?)ctl;
    if (seg != (UXSegmentedControl*)0)
        {
        seg.applyNativeSelection(value);
        }
    ctl.fire();
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        }
    }
// A native UITextField's text changed: the buffer is already synced shim-side;
// tell the neutral field so its onChange fires with the truth (mac pattern).
void uxGtkFieldChanged(i32 handle, i32 node)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)256)
        {
        return;
        }
    UXTextField* f = (UXTextField* ?)gGtkCtlPeer[handle * (i32)256 + node];
    if (f == (UXTextField*)0)
        {
        return;
        }
    f.fieldDidChange();
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        }
    }
void uxGtkFireControl(i32 handle, i32 node)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)256)
        {
        return;
        }
    UXControl* ctl = (UXControl* ?)gGtkCtlPeer[handle * (i32)256 + node];
    if (ctl == (UXControl*)0)
        {
        return;
        }
    if (gGtkClickEvent == (UXEvent*)0)
        {
        gGtkClickEvent = new UXEvent();
        }
    gGtkClickEvent.init();
    gGtkClickEvent.kind = (u8)UXEventMouseDown;
    UXRect cf = ctl.absoluteFrame();
    gGtkClickEvent.x = (i16)((i32)cf.x + (i32)cf.w / (i32)2);
    gGtkClickEvent.y = (i16)((i32)cf.y + (i32)cf.h / (i32)2);
    gGtkClickEvent.handle = handle;
    if (gEventTap != (callback void(UXEvent * e))0)
        {
        gEventTap(gGtkClickEvent);
        }
    ctl.mouseDown(gGtkClickEvent);
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        }
    }

// A press on something UXKit draws itself.  GTK's own loop owns the pointer, so
// this arrives as a callback rather than through the neutral nextEvent -- the
// same shape as AppKit's interactive mode, and for the same reason.
//
// The window is TAGGED on the event rather than hit-tested from the coordinate:
// the coordinates are already window-local, so two windows overlapping at the
// same local point would be indistinguishable.
UXEvent* gGtkMouseEvent;
i32 gGtkMouseWin;
void uxGtkDispatch(i32 kind, i32 x, i32 y, i32 handle)
    {
    if (gApp == (UXApplication*)0)
        {
        return;
        }
    if (gGtkMouseEvent == (UXEvent*)0)
        {
        gGtkMouseEvent = new UXEvent();
        }
    gGtkMouseEvent.init();
    gGtkMouseEvent.kind = (u8)kind;
    gGtkMouseEvent.x = (i16)x;
    gGtkMouseEvent.y = (i16)y;
    gGtkMouseEvent.handle = handle;
    gGtkMouseWin = handle;
    if (gEventTap != (callback void(UXEvent * e))0)
        {
        gEventTap(gGtkMouseEvent);
        }
    gApp.dispatchEvent(gGtkMouseEvent);
    gApp.displayIfNeeded();
    }

class UXGtkDriver : Object<UXViewDriver>
    {

    void init(void)
        {
        }

    // ---- boot / windows ------------------------------------------------------
    bool boot(i32* screenW, i32* screenH)
        {
        if (gGtkGfx == (UXCairoGraphics*)0)
            {
            gGtkGfx = new UXCairoGraphics();
            ux_gtk_set_control_fire((pointer)&uxGtkFireControl);
            ux_gtk_set_value_changed((pointer)&uxGtkValueChanged);
            ux_gtk_set_field_hooks((pointer)&uxGtkFieldChanged);
            ux_gtk_set_mouse((pointer)&uxGtkDispatch);
            }
        return ux_gtk_boot(screenW, screenH) != (i32)0;
        }
    i32 formFactorClass(void)
        {
        return (i32)UX_FORM_DESKTOP;
        }
    // desktop: the neutral loop pumps GTK
    bool driverOwnsRunLoop(void)
        {
        return false;
        }
    void runLoop(void)
        {
        }

    i32 windowCreate(i32 x, i32 y, i32 w, i32 h)
        {
        return ux_gtk_window_create(x, y, w, h);
        }
    void windowSetContent(i32 handle, pointer fn, pointer ud)
        {
        ux_gtk_window_set_content(handle, fn, ud);
        }
    void windowOpen(i32 handle, i32 x, i32 y, i32 w, i32 h)
        {
        ux_gtk_window_open(handle, x, y, w, h);
        }
    void windowDestroy(i32 handle)
        {
        ux_gtk_window_close(handle);
        }
    void windowSetTitle(i32 handle, u8* s)
        {
        ux_gtk_window_set_title(handle, s);
        }
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
        ux_gtk_window_front(handle);
        }
    // UIScrollView milestone
    void windowContentSize(i32 handle, i32 w, i32 h)
        {
        }
    i32 windowScrollX(i32 handle)
        {
        return (i32)0;
        }
    i32 windowScrollY(i32 handle)
        {
        return (i32)0;
        }
    void windowSetScroll(i32 handle, i32 x, i32 y)
        {
        }
    void windowContentGeometry(i32 handle, i32* w, i32* h)
        {
        ux_gtk_content_geometry(handle, w, h);
        }
    void windowInvalidate(i32 handle)
        {
        ux_gtk_window_invalidate(handle);
        }
    void windowInvalidateRect(i32 handle, i32 x, i32 y, i32 w, i32 h)
        {
        ux_gtk_window_invalidate(handle);
        }

    // ---- native panels: none yet — toolkit fallbacks take over ---------------
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

    // ---- time / settings / measurement ---------------------------------------
    i32 nowMs(void)
        {
        return ux_gtk_now_ms();
        }
    void nowUTC(i32* out7)
        {
        ux_gtk_now_utc(out7);
        }
    i32 localOffsetMinutes(void)
        {
        return ux_gtk_local_offset_minutes();
        }
    bool settingGet(u8* domain, u8* key, u8* out, i32 cap)
        {
        return ux_gtk_setting_get(domain, key, out, cap) != (i32)0;
        }
    bool settingSet(u8* domain, u8* key, u8* value)
        {
        return ux_gtk_setting_set(domain, key, value) != (i32)0;
        }
    bool settingRemove(u8* domain, u8* key)
        {
        return ux_gtk_setting_remove(domain, key) != (i32)0;
        }
    i32 textWidth(u8* s, i32 size)
        {
        return ux_gtk_text_width(s, (u8*)"", size, (i32)0, (i32)0);
        }
    i32 textWidthStyled(u8* s, u8* family, i32 size, bool bold, bool italic)
        {
        return ux_gtk_text_width(s, family, size, bold ? (i32)1 : (i32)0, italic ? (i32)1 : (i32)0);
        }
    i32 runPopupMenu(pointer peer, i32 x, i32 y)
        {
        return (i32)-1;
        }
    // font panel milestone
    i32 fontFamilyCount(void)
        {
        return (i32)0;
        }
    i32 fontFamilyName(i32 idx, u8* out, i32 cap)
        {
        return (i32)-1;
        }

    // ---- the shadow tree (the shared implementation) -------------------------
    pointer structNew(void)
        {
        GKTree* t = (GKTree*)malloc((u32)sizeof(GKTree));
        t.cap = (i32)16;
        t.count = (i32)0;
        t.win = (i32)0;
        t.nodes = (GKNode*)calloc((u32)t.cap, (u32)sizeof(GKNode));
        return (pointer)t;
        }
    void structFree(pointer h)
        {
        if (h == (pointer)0)
            {
            return;
            }
        GKTree* t = (GKTree*)h;
        if (t.nodes != (GKNode*)0)
            {
            free((pointer)t.nodes);
            }
        free(h);
        }
    void structAdopt(pointer h, pointer t, i32 n)
        {
        }
    pointer structObjects(pointer h)
        {
        return h;
        }
    i32 structLength(pointer h)
        {
        return ((GKTree*)h).count;
        }
    void structGrow(pointer h, i32 want)
        {
        GKTree* t = (GKTree*)h;
        if (want <= t.cap)
            {
            return;
            }
        i32 cap = t.cap;
        while (cap < want)
            {
            cap = cap * (i32)2;
            }
        t.nodes = (GKNode*)realloc((pointer)t.nodes, (u32)cap * (u32)sizeof(GKNode));
        t.cap = cap;
        }
    i32 structAppend(pointer h, i32 kind, i32 x, i32 y, i32 w, i32 ht)
        {
        GKTree* t = (GKTree*)h;
        self.structGrow(h, t.count + (i32)1);
        i32 i = t.count;
        GKNode* n = &t.nodes[i];
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
        GKNode* t = ((GKTree*)h).nodes;
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
        GKNode* t = ((GKTree*)h).nodes;
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
        self.pushHiddenSubtree(h, child); // it is off the tree; take it off screen
        }
    void structFinalise(pointer h)
        {
        }
    void structSetFrame(pointer h, i32 i, i32 x, i32 y, i32 w, i32 ht)
        {
        GKNode* n = &((GKTree*)h).nodes[i];
        n.x = (i16)x;
        n.y = (i16)y;
        n.w = (i16)w;
        n.h = (i16)ht;
        GKTree* t = (GKTree*)h;
        if (t.win != (i32)0 && ux_gtk_has_control(t.win, i) != (i32)0)
            {
            i32 ax = (i32)0;
            i32 ay = (i32)0;
            i32 aw = (i32)0;
            i32 ah = (i32)0;
            self.structAbsFrame(h, i, &ax, &ay, &aw, &ah);
            ux_gtk_set_control_frame(t.win, i, ax, ay, aw, ah);
            }
        }
    void structFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
        {
        GKNode* n = &((GKTree*)h).nodes[i];
        x[0] = (i32)n.x;
        y[0] = (i32)n.y;
        w[0] = (i32)n.w;
        ht[0] = (i32)n.h;
        }
    void structSetHidden(pointer h, i32 i, i32 on)
        {
        ((GKTree*)h).nodes[i].hidden = (i16)on;
        self.pushHiddenSubtree(h, i);
        }

    // HIDDEN IS INHERITED — see UXAppKitDriver.effectiveHidden for the full
    // reasoning.  In short: a native control is its own platform view, so it
    // does not disappear because an ancestor did; the app-drawn walk skips a
    // hidden subtree while native controls stayed visible, and the two halves
    // of one tree disagreed about what "hidden" means.
    //
    // VERIFIED on GTK by test_hiddeninherit_gtk.xc (gate `hiddeninherit-gtk`):
    // a container of native controls, hidden AFTER realize, swapped both ways.
    // Node 0 is the root.  Walking parents must reach it; hitting -1 first
    // means this node was removed from the tree and is merely still occupying
    // its slot in the array.
    i32 isDetached(pointer h, i32 i)
        {
        GKNode* t = ((GKTree*)h).nodes;
        i32 cur = i;
        i32 guard = (i32)0;
        while (guard <= (i32)256)
            {
            // reached the root
            if (cur == (i32)0)
                {
                return (i32)0;
                }
            if (t[cur].parent < (i16)0)
                {
                return (i32)1;
                }
            cur = (i32)t[cur].parent;
            guard = guard + (i32)1;
            }
        return (i32)0;
        }
    i32 effectiveHidden(pointer h, i32 i)
        {
        GKNode* t = ((GKTree*)h).nodes;
        // DETACHED COUNTS AS HIDDEN.  structRemoveChild unlinks a node and
        // leaves parent = -1, but realizeTree walks every node in the array,
        // and structAbsFrame on a parentless node returns its LOCAL
        // coordinates — so a removed view was re-realized at the window's
        // top-left, on top of everything.  A node that cannot be reached from
        // the root is not in the interface, so it is not shown.
        if (self.isDetached(h, i) != (i32)0)
            {
            return (i32)1;
            }
        i32 cur = i;
        i32 guard = (i32)0;
        while (cur >= (i32)0 && guard <= (i32)256)
            {
            if (t[cur].hidden != (i16)0)
                {
                return (i32)1;
                }
            cur = (i32)t[cur].parent;
            guard = guard + (i32)1; // a malformed tree must not hang the UI
            }
        return (i32)0;
        }
    // Push the effective state to a node and everything under it, so hiding a
    // container takes effect on the next paint rather than the next realize.
    void pushHiddenSubtree(pointer h, i32 i)
        {
        GKTree* t = (GKTree*)h;
        if (i < (i32)0 || i >= t.count)
            {
            return;
            }
        if (t.win != (i32)0 && ux_gtk_has_control(t.win, i) != (i32)0)
            {
            ux_gtk_set_control_hidden(t.win, i, self.effectiveHidden(h, i));
            }
        i32 c = (i32)t.nodes[i].head;
        i32 guard = (i32)0;
        while (c >= (i32)0 && c < t.count && guard <= t.count)
            {
            self.pushHiddenSubtree(h, c);
            c = (i32)t.nodes[c].next;
            guard = guard + (i32)1;
            }
        }
    i32 structIsHidden(pointer h, i32 i)
        {
        return (i32)((GKTree*)h).nodes[i].hidden;
        }
    void structSetEnabled(pointer h, i32 i, i32 on)
        {
        ((GKTree*)h).nodes[i].enabled = (i16)on;
        GKTree* t = (GKTree*)h;
        if (t.win != (i32)0 && ux_gtk_has_control(t.win, i) != (i32)0)
            {
            ux_gtk_set_control_enabled(t.win, i, on);
            }
        }
    i32 structIsEnabled(pointer h, i32 i)
        {
        return (i32)((GKTree*)h).nodes[i].enabled;
        }
    void structSetSelected(pointer h, i32 i, i32 on)
        {
        ((GKTree*)h).nodes[i].selected = (i16)on;
        }
    i32 structIsSelected(pointer h, i32 i)
        {
        return (i32)((GKTree*)h).nodes[i].selected;
        }
    void structSetClips(pointer h, i32 i, i32 on)
        {
        ((GKTree*)h).nodes[i].clips = (i16)on;
        }
    void structSetSpec(pointer h, i32 i, pointer spec)
        {
        ((GKTree*)h).nodes[i].spec = spec;
        }
    void structSetPeer(pointer h, i32 i, pointer peer)
        {
        ((GKTree*)h).nodes[i].peer = peer;
        }
    // UIKit autoresizing masks later
    void structSetAutoresize(pointer h, i32 i, i32 mask)
        {
        }
    bool driverAutoresizes(void)
        {
        return false;
        }
    void structSetSelectable(pointer h, i32 i, i32 on)
        {
        ((GKTree*)h).nodes[i].selectable = (i16)on;
        }
    void structSetEditable(pointer h, i32 i, i32 on)
        {
        ((GKTree*)h).nodes[i].editable = (i16)on;
        }

    void treeOffset(pointer tree, i32 obj, i32* ax, i32* ay)
        {
        ax[0] = (i32)0;
        ay[0] = (i32)0;
        }
    void structAbsFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
        {
        GKNode* t = ((GKTree*)h).nodes;
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
    i32 hitOne(GKNode* t, i32 i, i32 ox, i32 oy, i32 px, i32 py)
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
        return self.hitOne(((GKTree*)tree).nodes, start, (i32)0, (i32)0, x, y);
        }

    // ---- native realization --------------------------------------------------
    // Real UIKit controls overlay the shadow tree: a UIButton per XGKindButton,
    // a UILabel per Label — created once, repositioned thereafter, peers parked
    // for the fire path.  The custom-view kinds stay app-drawn through drawRect.
    // A toggle's on/off state, read from the PEER widget -- the peer owns it,
    // the shadow node only mirrors it.  Same read as the AppKit driver's.
    // A control's text alignment, read from its PEER -- the same shape as
    // toggleState: alignment lives on the control, not in the shadow tree.
    i32 alignOf(pointer peer)
        {
        UXControl* c = (UXControl* ?)peer;
        if (c == (UXControl*)0)
            {
            return (i32)UX_ALIGN_LEFT;
            }
        return c.alignment();
        }

    i32 toggleState(pointer peer, i32 k)
        {
        if (k == (i32)UXKindCheckbox)
            {
            UXCheckbox* cb = (UXCheckbox* ?)peer;
            if (cb != (UXCheckbox*)0 && cb.isChecked())
                {
                return (i32)1;
                }
            }
        else
            {
            UXRadioButton* rb = (UXRadioButton* ?)peer;
            if (rb != (UXRadioButton*)0 && rb.isSelected())
                {
                return (i32)1;
                }
            }
        return (i32)0;
        }

    void realizeTree(i32 handle, pointer tree)
        {
        GKTree* t = (GKTree*)tree;
        t.win = handle;
        for (i32 i = (i32)0; i < t.count; i = i + (i32)1)
            {
            GKNode* n = &t.nodes[i];
            i32 ax = (i32)0;
            i32 ay = (i32)0;
            i32 aw = (i32)0;
            i32 ah = (i32)0;
            self.structAbsFrame(tree, i, &ax, &ay, &aw, &ah);
            if ((i32)n.kind == (i32)UXKindShield)
                {
                ux_gtk_make_shield(handle, ax, ay, aw, ah, self.effectiveHidden(tree, i));
                continue;
                }
            if (ux_gtk_has_control(handle, i) != (i32)0)
                {
                ux_gtk_set_control_frame(handle, i, ax, ay, aw, ah);
                ux_gtk_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                ux_gtk_set_control_enabled(handle, i, (i32)n.enabled);
                // ...and the TOGGLE state, which this branch used to omit.  The
                // creation path below reads it from the peer, so a fresh form
                // looked right and only a LATER change went stale -- a check box
                // whose model says on while the switch on screen says off.  Every
                // other backend pushes it on each display (AppKit
                // ux_ak_set_control_check, Win32 BM_SETCHECK); GTK was the one
                // that did not.
                if ((i32)n.kind == (i32)UXKindCheckbox || (i32)n.kind == (i32)UXKindRadio)
                    {
                    ux_gtk_set_check(handle, i, self.toggleState(n.peer, (i32)n.kind));
                    }
                // ...and alignment, every pass for the same reason: it changes
                // after realize when an editor's inspector sets it.
                if ((i32)n.kind == (i32)UXKindLabel || (i32)n.kind == (i32)UXKindField)
                    {
                    ux_gtk_set_align(handle, i, self.alignOf(n.peer));
                    }
                continue;
                }
            if (n.kind == (i32)UXKindButton)
                {
                u8* title = n.spec != (pointer)0 ? (u8*)n.spec : (u8*)"";
                ux_gtk_make_button(handle, i, ax, ay, aw, ah, title);
                gGtkCtlPeer[handle * (i32)256 + i] = n.peer;
                }
            else if (n.kind == (i32)UXKindLabel && n.spec != (pointer)0)
                {
                ux_gtk_make_label(handle, i, ax, ay, aw, ah, (u8*)n.spec);
                }
            else if (n.kind == (i32)UXKindField)
                {
                GKField* f = (GKField*)n.spec;
                if (f != (GKField*)0)
                    {
                    ux_gtk_make_field(handle, i, ax, ay, aw, ah, f.buf, f.cap, f.secure);
                    gGtkCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindCheckbox)
                {
                // The platform's toggle idiom IS the switch — checked state
                // from the peer, exactly the mac driver's toggleState read.
                UXCheckbox* cb = (UXCheckbox* ?)n.peer;
                if (cb != (UXCheckbox*)0)
                    {
                    u8* title = n.spec != (pointer)0 ? (u8*)n.spec : (u8*)"";
                    ux_gtk_make_check(handle, i, ax, ay, aw, ah, title,
                                      cb.isChecked() ? (i32)1 : (i32)0);
                    gGtkCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindSlider)
                {
                UXSlider* sv = (UXSlider* ?)n.peer;
                if (sv != (UXSlider*)0)
                    {
                    ux_gtk_make_slider(handle, i, ax, ay, aw, ah,
                                       sv.nativeMin(), sv.nativeMax(), sv.nativeValue());
                    gGtkCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindStepper)
                {
                UXStepper* sv = (UXStepper* ?)n.peer;
                if (sv != (UXStepper*)0)
                    {
                    ux_gtk_make_stepper(handle, i, ax, ay, aw, ah,
                                        sv.nativeMin(), sv.nativeMax(), sv.nativeStep(),
                                        sv.nativeWraps() ? (i32)1 : (i32)0, sv.nativeValue());
                    gGtkCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindProgress)
                {
                UXProgressBar* pgv = (UXProgressBar* ?)n.peer;
                if (pgv != (UXProgressBar*)0)
                    {
                    ux_gtk_make_progress(handle, i, ax, ay, aw, ah, pgv.nativeFractionMille());
                    gGtkCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindPopup)
                {
                UXPopUpButton* pv = (UXPopUpButton* ?)n.peer;
                if (pv != (UXPopUpButton*)0)
                    {
                    ux_gtk_make_popup(handle, i, ax, ay, aw, ah);
                    for (i32 j = (i32)0; j < pv.nativeItemCount(); j = j + (i32)1)
                        {
                        ux_gtk_popup_add_item(handle, i, pv.nativeItemTitle(j));
                        }
                    ux_gtk_popup_select(handle, i, pv.nativeSelected());
                    gGtkCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindSegmented)
                {
                UXSegmentedControl* gv = (UXSegmentedControl* ?)n.peer;
                if (gv != (UXSegmentedControl*)0)
                    {
                    ux_gtk_make_segmented(handle, i, ax, ay, aw, ah, gv.nativeSegCount());
                    for (i32 j = (i32)0; j < gv.nativeSegCount(); j = j + (i32)1)
                        {
                        ux_gtk_seg_set_label(handle, i, j, gv.nativeSegLabel(j));
                        }
                    ux_gtk_seg_select(handle, i, gv.nativeSelectedSeg());
                    gGtkCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            // apply the node's INITIAL state to a control created THIS pass —
            // the has-control branch above only serves later displays, so a
            // widget disabled/hidden before its first realize stayed pristine
            // (the state-pair portraits caught identical enabled/disabled
            // buttons on every single-pass backend)
            if (ux_gtk_has_control(handle, i) != (i32)0)
                {
                if (n.enabled == (i16)0)
                    {
                    ux_gtk_set_control_enabled(handle, i, (i32)0);
                    }
                if (self.effectiveHidden(tree, i) != (i32)0)
                    {
                    ux_gtk_set_control_hidden(handle, i, (i32)1);
                    }
                }
            }
        // Anything realized this pass went in above the shield; put it back on
        // top, or the shield works only until the next widget appears.
        if (ux_gtk_has_shield(handle) != (i32)0)
            {
            ux_gtk_raise_shield(handle);
            }
        }

    // ---- painting ------------------------------------------------------------
    void treeSetUserDraw(pointer fn, pointer ud)
        {
        gGtkUserFn = fn;
        gGtkUserUd = ud;
        }
    void drawOne(GKTree* t, i32 i)
        {
        if (i < (i32)0 || t.nodes[i].hidden != (i16)0)
            {
            return;
            }
        i32 k = t.nodes[i].kind;
        // A node with a native control paints itself — never draw under it.
        bool native = t.win != (i32)0 && ux_gtk_has_control(t.win, i) != (i32)0;
        if (!native)
            {
            // The GEM rule: every non-native node is app-drawn through the
            // userdraw seam — View AND the custom-drawn controls.  (Same gap,
            // same fix as the web driver; the capture pipeline found it.)
            if (gGtkUserFn != (pointer)0)
                {
                UXGtkUserDrawFn* f = (UXGtkUserDrawFn*)gGtkUserFn;
                f((pointer)t.nodes, i, gGtkUserUd);
                }
            }
        bool clips = t.nodes[i].clips != (i16)0;
        if (clips)
            {
            i32 cx = (i32)0;
            i32 cy = (i32)0;
            i32 cw = (i32)0;
            i32 chh = (i32)0;
            self.structAbsFrame((pointer)t, i, &cx, &cy, &cw, &chh);
            ux_gtk_clip(cx, cy, cw, chh);
            }
        i16 c = t.nodes[i].head;
        while (c >= (i16)0)
            {
            self.drawOne(t, (i32)c);
            c = t.nodes[c].next;
            }
        if (clips)
            {
            ux_gtk_clip_end();
            }
        }
    void treeDraw(pointer tree, i32 start, i32 clx, i32 cly, i32 clw, i32 clh)
        {
        gGtkDrawTree = (GKTree*)tree;
        self.drawOne((GKTree*)tree, start);
        }
    UXGraphics* beginViewDraw(i32 ax, i32 ay, i32 aw, i32 ah)
        {
        gGtkGfx.bind(UXGeom.make((i16)(ax - gGtkDrawOX), (i16)(ay - gGtkDrawOY), (i16)aw, (i16)ah));
        return gGtkGfx;
        }
    void setDrawOffset(i32 x, i32 y)
        {
        gGtkDrawOX = x;
        gGtkDrawOY = y;
        }
    // UIScrollView milestone
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

    // ---- text editing (the shared engine; the UITextField overlay is a milestone) ----
    pointer fieldEditorNew(u8* buf, i32 cap)
        {
        GKField* f = (GKField*)malloc((u32)sizeof(GKField));
        f.buf = buf;
        f.cap = cap;
        f.valid = (u8*)0;
        f.place = (u8*)0;
        f.secure = (i32)0;
        return (pointer)f;
        }
    void fieldEditorSetValid(pointer ed, u8* valid)
        {
        ((GKField*)ed).valid = valid;
        }
    void fieldEditorSetPlaceholder(pointer ed, u8* s)
        {
        ((GKField*)ed).place = s;
        }
    void fieldEditorSetSecure(pointer ed, i32 on)
        {
        ((GKField*)ed).secure = on;
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
        if (code == (u8)57)
            {
            return ch >= (i32)48 && ch <= (i32)57;
            }
        if (code == (u8)65)
            {
            return (ch >= (i32)65 && ch <= (i32)90) || ch == (i32)32;
            }
        if (code == (u8)97)
            {
            return (ch >= (i32)97 && ch <= (i32)122) || (ch >= (i32)65 && ch <= (i32)90);
            }
        return true;
        }
    i32 editText(pointer tree, i32 obj, i32 key, i32* caret, i32 mode)
        {
        GKField* f = (GKField*)((GKTree*)tree).nodes[obj].spec;
        if (f == (GKField*)0)
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
        if (ch < (i32)32 || ch > (i32)126)
            {
            return (i32)0;
            }
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
            u8 code = c < vlen ? f.valid[c] : (u8)88;
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

    // ---- menus / alerts: their milestones (UIMenu, UIAlertController) --------
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
    // Modal for real: GtkAlertDialog behind a nested GMainLoop in the shim —
    // the async choose() made synchronous, the same shape as NSAlert's
    // runModal.  Dismissal (Esc / close) reports the LAST button, the
    // platform's cancel convention.
    i32 alertRun(i32 icon, u8* lines, u8* buttons, i32 defaultBtn)
        {
        return ux_gtk_alert((i32)1, lines, buttons, defaultBtn);
        }

    // ---- events: input arrives via signals, never through ev — but the WAIT
    // is real: nextEvent sleeps in g_main_context_iteration until one source
    // dispatches (input, redraw, timer).  Signals run inline during the wait,
    // so the neutral state has advanced by the time run()'s loop re-checks
    // isRunning.  That is the whole desktop-loop contract (gtk-loop gate).
    void nextEvent(i32 timeoutMs, UXEvent* ev)
        {
        ev.init();
        ux_gtk_wait_event();
        }
    void pumpMessages(i32 timeoutMs, UXEvent* ev)
        {
        ev.init();
        ux_gtk_pump();
        }
    // The window the pointer event actually came from, not a guess from the
    // coordinates -- GTK hands us the widget, so there is nothing to guess.
    i32 windowAtPoint(i32 x, i32 y)
        {
        return gGtkMouseWin;
        }
    // Toolkit-drawn drags (a split divider, a slider thumb, an editor moving an
    // object) block here until the pointer moves or the button releases.  This
    // used to return 0, which meant every such drag on Linux did nothing at
    // all: the loop that calls it exited before its first step.
    i32 trackDragStep(i32* x, i32* y)
        {
        // see gInputReplay (UXEvent.xc)
        if (gInputReplay)
            {
            return (i32)0;
            }
        return ux_gtk_drag_next(x, y);
        }

    i32 liveNativeCount(void)
        {
        return ux_gtk_native_count();
        }
    }
