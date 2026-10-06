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
#import "UXTableView.xc"        // the native GtkColumnView reads its rows from the peer table
#import "UXScrollView.xc"       // a scroll view is a GtkScrolledWindow
#import "UXOutlineView.xc"      // ...and a native tree reads its items from the peer outline
#import "UXTextView.xc"         // a GtkTextView edits it
#import "UXApplication.xc"      // gApp: the driver-owned loop starts the delegate, and stop() quits
#import "UXLibc.xc"

// The shim (libUXIos.m).  Primitive signatures only — no CGRect crosses into xtc.
i32 ux_gtk_boot(i32* w, i32* h);
void ux_gtk_pump(void);
void ux_gtk_wait_event(void);
void ux_gtk_wait_event_ms(i32 ms);
i32 ux_gtk_alert(i32 parent, u8* lines, u8* buttons, i32 defBtn);
void ux_gtk_clip(i32 x, i32 y, i32 w, i32 h);
void ux_gtk_clip_round(i32 x, i32 y, i32 w, i32 h, i32 r); // ...with rounded corners; ux_gtk_clip_end pops
i32 ux_gtk_audio_play(i16* pcm, i32 frames, i32 rate); // PulseAudio, 1 = started
pointer ux_gtk_menu_new(void);                      // the menu bar (libUXGtk.c)
i32 ux_gtk_menu_add_title(pointer bar, u8* title);
void ux_gtk_menu_add_item(pointer bar, i32 t, i32 j, u8* text, i32 checked, i32 disabled, i32 sep);
void ux_gtk_menu_show(pointer bar, i32 show);
void ux_gtk_menu_check(i32 t, i32 j, i32 on);
void ux_gtk_menu_enable(i32 t, i32 j, i32 on);
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
i32 ux_gtk_window_snapshot(i32 handle, i32 x, i32 y, i32 w, i32 h, u32* out);
i32 ux_gtk_native_count(void);
i32 ux_gtk_has_control(i32 handle, i32 node);
void ux_gtk_make_button(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* title);
// The native table (GtkColumnView), fed by the peer UXTableView through these hooks.
void ux_gtk_set_table_hooks(pointer rows, pointer cell, pointer cols, pointer title, pointer width, pointer multi, pointer selset);
void ux_gtk_make_table(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, pointer peer);
void ux_gtk_table_reload(i32 handle, i32 node);
void ux_gtk_table_select(i32 handle, i32 node, i32* rows, i32 n);
// ...and the native outline (a GtkTreeListModel), fed by the peer UXOutlineView.
void ux_gtk_set_outline_hooks(pointer children, pointer child, pointer expandable, pointer value, pointer didexpand, pointer isexpanded);
void ux_gtk_make_outline(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, pointer peer);
void ux_gtk_outline_reload(i32 handle, i32 node);
void ux_gtk_make_label(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* text);
void ux_gtk_set_control_frame(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h);
void ux_gtk_set_control_enabled(i32 handle, i32 node, i32 on);
void ux_gtk_set_control_hidden(i32 handle, i32 node, i32 on);
void ux_gtk_set_control_fire(pointer fn);
void ux_gtk_set_value_changed(pointer fn);
void ux_gtk_make_check(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* title, i32 on);
// A radio: a GtkCheckButton grouped with the radio at node `leader` (-1: none -- it gets a hidden
// partner, so it still draws round).
void ux_gtk_make_radio(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* title, i32 on, i32 leader);
void ux_gtk_set_check(i32 handle, i32 node, i32 on);
void ux_gtk_make_slider(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 lo, i32 hi, i32 val);
void ux_gtk_set_slider_value(i32 handle, i32 node, i32 val);
i32 ux_gtk_gl_drawable(i32 handle, i32 node, i32* pw, i32* ph);
i32 ux_gtk_gl_read(i32 handle, i32 node, u32* out, i32 pw, i32 ph);
void ux_gtk_make_stepper(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 lo, i32 hi, i32 step, i32 wraps, i32 val);
void ux_gtk_set_stepper_value(i32 handle, i32 node, i32 val);
void ux_gtk_make_progress(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 mille);
void ux_gtk_set_progress(i32 handle, i32 node, i32 mille, i32 indeterminate);
void ux_gtk_make_popup(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h);
void ux_gtk_set_field_hooks(pointer fn);
void ux_gtk_set_field_submit_hooks(pointer fn);
void ux_gtk_set_mouse(pointer fn); // register the pointer-event forwarder
// native scroll containers: a GtkScrolledWindow whose document draws the scroll view's subtree
void ux_gtk_set_scroll_content(pointer fn);
void ux_gtk_make_scroll(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 contentH, pointer sv, i32 docX, i32 docY);
void ux_gtk_scroll_reload(i32 handle, i32 node, i32 w, i32 h, i32 contentH, i32 docX, i32 docY);
void ux_gtk_scroll_set(i32 handle, i32 node, i32 px);
i32 ux_gtk_scroll_get(i32 handle, i32 node);
void ux_gtk_reparent_to_scroll(i32 handle, i32 node, i32 scrollNode, i32 ax, i32 ay);
void ux_gtk_scroll_style(i32 handle, i32 node, i32 radius, i32 rgb);
// The input shield (UXKindShield): a bare widget above the controls, so a click on a
// design surface reaches the toolkit instead of operating the widget under it.
void ux_gtk_make_shield(i32 handle, i32 x, i32 y, i32 w, i32 h, i32 hidden);
void ux_gtk_raise_shield(i32 handle);
i32 ux_gtk_has_shield(i32 handle);
i32 ux_gtk_shield_on_top(i32 handle);
// The GL surface (UXKindGLView).  The shim makes a real GtkGLArea at realization and the
// context only when the app asks; the driver reaches both through these, and the entry
// points through glProc.  A null name, or one the platform has not got, resolves to 0.
void ux_gtk_make_gl(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 hidden);
i32 ux_gtk_gl_make_current(i32 handle, i32 node);
void ux_gtk_gl_viewport(i32 handle, i32 node);
void ux_gtk_gl_present(i32 handle, i32 node);
i32 ux_gtk_gl_error(i32 handle, i32 node);
pointer ux_gtk_gl_proc(u8* name);
void ux_gtk_set_align(i32 handle, i32 node, i32 a); // label/entry text alignment
i32 ux_gtk_get_align(i32 handle, i32 node);         // ...and what it actually is
i32 ux_gtk_drag_next(i32* x, i32* y);               // one modal drag-track step: 1 = dragging, 0 = up
void ux_gtk_post_press(i32 handle, i32 x, i32 y);   // test seam: a headless gate has no pointer
void ux_gtk_post_motion(i32 x, i32 y);
void ux_gtk_post_release(void);
void ux_gtk_make_field(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* buf, i32 cap, i32 secure);
// The native text view (UXTextView): a GtkTextView in a GtkScrolledWindow.
void ux_gtk_make_textview(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h);
void ux_gtk_textview_set_hooks(pointer changed, pointer selected, pointer undo);
void ux_gtk_textview_set_all(i32 handle, i32 node, u8* text, i32 nbytes, i32* runs, i32 nruns);
void ux_gtk_textview_replace(i32 handle, i32 node, i32 start, i32 len, u8* text, i32 nbytes, i32* runs, i32 nruns,
                             i32 attrsOnly);
void ux_gtk_textview_size(i32 handle, i32 node, i32* nbytes, i32* nruns);
i32 ux_gtk_textview_read(i32 handle, i32 node, u8* buf, i32 cap, i32* runs, i32 maxRuns);
void ux_gtk_textview_selection(i32 handle, i32 node, i32* start, i32* len);
void ux_gtk_textview_set_selection(i32 handle, i32 node, i32 start, i32 len);
void ux_gtk_textview_set_typing(i32 handle, i32 node, i32 flags, i32 colour, i32 size);
void ux_gtk_textview_focus(i32 handle, i32 node);
void ux_gtk_textview_set_look(i32 handle, i32 node, i32 bg, i32 ink, i32 caret, i32 sel, i32 size, i32 mono);
void ux_gtk_update_field(i32 handle, i32 node);
void ux_gtk_popup_add_item(i32 handle, i32 node, u8* title);
void ux_gtk_popup_select(i32 handle, i32 node, i32 i);
void ux_gtk_make_segmented(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 nseg);
void ux_gtk_seg_set_label(i32 handle, i32 node, i32 seg, u8* label);
void ux_gtk_seg_select(i32 handle, i32 node, i32 seg);
i32 ux_gtk_text_width(u8* s, u8* family, i32 size, i32 bold, i32 italic);
i32 ux_gtk_text_width_weight(u8* s, u8* family, i32 size, i32 weight, i32 italic);
i32 ux_gtk_text_ascent(u8* family, i32 size, i32 weight, i32 italic);
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
    i16 clipR;     // a clipping node's corner radius (structSetClipShape)
    i16 clipIn;    // ...and the inset of its clip from its frame
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
pointer gGtkCtlPeer[262144]; // [handle*4096 + node] (UX_MAXN in the shim) -> the control's neutral widget
UXEvent* gGtkClickEvent;
// A native value control moved: adopt the number into the peer, fire its
// action — the mac driver's xgAKValueChanged, iOS edition (the UISwitch case
// is new: its 0/1 lands in the peer UXCheckbox before the fire).
void uxGtkValueChanged(i32 handle, i32 node, i32 value)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)4096)
        {
        return;
        }
    UXControl* ctl = (UXControl* ?)(Object*)gGtkCtlPeer[handle * (i32)4096 + node];
    if (ctl == (UXControl*)0)
        {
        return;
        }
    UXCheckbox* cb = (UXCheckbox* ?)ctl;
    if (cb != (UXCheckbox*)0)
        {
        cb.setChecked(value != (i32)0);
        }
    // A radio: switched ON selects it through its group (which clears the others, and fires); the
    // OFF that GTK's own grouping sends to the previous one is the group's business, already done.
    UXRadioButton* rb = (UXRadioButton* ?)ctl;
    if (rb != (UXRadioButton*)0)
        {
        if (value == (i32)0)
            {
            return;
            }
        if (rb.group != (UXRadioGroup*)0)
            {
            rb.group.select(rb);
            }
        else
            {
            rb.setSelected(true);
            }
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
// The user edited a GtkTextView, moved its selection or pressed an undo key: tell its UXTextView.
UXTextView* uxGtkTextViewAt(i32 handle, i32 node)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)4096)
        {
        return (UXTextView*)0;
        }
    return (UXTextView* ?)(Object*)gGtkCtlPeer[handle * (i32)4096 + node];
    }
void uxGtkTextViewChanged(i32 handle, i32 node)
    {
    UXTextView* tv = uxGtkTextViewAt(handle, node);
    if (tv != (UXTextView*)0)
        {
        tv.nativeDidChange();
        }
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        }
    }
void uxGtkTextViewSelected(i32 handle, i32 node)
    {
    UXTextView* tv = uxGtkTextViewAt(handle, node);
    if (tv != (UXTextView*)0)
        {
        tv.nativeDidSelect();
        }
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        }
    }
void uxGtkTextViewUndo(i32 handle, i32 node, i32 redo)
    {
    UXTextView* tv = uxGtkTextViewAt(handle, node);
    if (tv != (UXTextView*)0)
        {
        if (redo != (i32)0)
            {
            tv.redo();
            }
        else
            {
            tv.undo();
            }
        }
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        }
    }

void uxGtkFieldChanged(i32 handle, i32 node)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)4096)
        {
        return;
        }
    UXTextField* f = (UXTextField* ?)(Object*)gGtkCtlPeer[handle * (i32)4096 + node];
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
// Return in a native GtkEntry: the field's onSubmit.  The buffer is already synced (entry_cb runs
// per keystroke), so this announces and nothing else.
void uxGtkFieldSubmitted(i32 handle, i32 node)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)4096)
        {
        return;
        }
    UXTextField* f = (UXTextField* ?)(Object*)gGtkCtlPeer[handle * (i32)4096 + node];
    if (f == (UXTextField*)0)
        {
        return;
        }
    f.fieldDidSubmit();
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        }
    }
void uxGtkFireControl(i32 handle, i32 node)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)4096)
        {
        return;
        }
    UXControl* ctl = (UXControl* ?)(Object*)gGtkCtlPeer[handle * (i32)4096 + node];
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
void uxGtkDispatch(i32 kind, i32 x, i32 y, i32 handle, i32 extra)
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
    if (kind == (i32)UXEventMenuSelect)
        {
        gGtkMouseEvent.a = x + (i32)2; // the title's GEM object number, as handleSelection expects
        gGtkMouseEvent.b = y;          // the item's ordinal
        }
    if (kind == (i32)UXEventWheel)
        {
        gGtkMouseEvent.b = extra;                   // the DOM's deltaY in pixels, positive down
        gGtkMouseEvent.a = (i32)0 - extra / (i32)100; // notches, positive up
        }
    gGtkMouseWin = handle;
    if (gEventTap != (callback void(UXEvent * e))0)
        {
        gEventTap(gGtkMouseEvent);
        }
    gApp.dispatchEvent(gGtkMouseEvent);
    gApp.displayIfNeeded();
    }

// the drawn file panel's file operations (ux_posix_fs.h, compiled into the shim)
i32 ux_posix_listdir(u8* path, u8* out, i32 cap);
i32 ux_gtk_file_open(u8* prompt, u8* startDir, u8* out, i32 cap);
i32 ux_gtk_file_save(u8* prompt, u8* startDir, u8* defName, u8* out, i32 cap);
i32 ux_gtk_pick_color(i32 r, i32 g, i32 b, i32* outR, i32* outG, i32* outB);
i32 ux_gtk_pick_font(u8* inFamily, i32 inSize, i32 inBold, i32 inItalic, u8* outFamily, i32 cap, i32* outSize, i32* outBold, i32* outItalic);
i32 ux_posix_delete(u8* path);
i32 ux_posix_rename(u8* src, u8* dst);
i32 ux_posix_copy(u8* src, u8* dst);

// Table-data trampolines for the native GtkColumnView: the shim calls these with the peer
// UXTableView, so the SAME neutral datasource that feeds the drawn table feeds the native one.
i32 xgGtkTableRows(pointer tbl)
    {
    return ((UXTableView* ?)(Object*)tbl).nativeRowCount();
    }
u8* xgGtkTableCell(pointer tbl, i32 r, i32 c)
    {
    return ((UXTableView* ?)(Object*)tbl).nativeCellText(r, c);
    }
i32 xgGtkTableCols(pointer tbl)
    {
    return ((UXTableView* ?)(Object*)tbl).numberOfColumns();
    }
u8* xgGtkTableColTitle(pointer tbl, i32 c)
    {
    return ((UXTableView* ?)(Object*)tbl).columnTitle(c);
    }
i32 xgGtkTableColWidth(pointer tbl, i32 c)
    {
    return (i32)((UXTableView* ?)(Object*)tbl).columnWidth(c);
    }
i32 xgGtkTableMulti(pointer tbl)
    {
    return ((UXTableView* ?)(Object*)tbl).nativeAllowsMultiple();
    }
// Outline-item trampolines: the shim's tree model asks the peer UXOutlineView for each item.
i32 xgGtkOutlineChildren(pointer o, pointer item)
    {
    return ((UXOutlineView* ?)(Object*)o).nativeChildren(item);
    }
pointer xgGtkOutlineChild(pointer o, pointer item, i32 i)
    {
    return ((UXOutlineView* ?)(Object*)o).nativeChild(item, i);
    }
i32 xgGtkOutlineExpandable(pointer o, pointer item)
    {
    return ((UXOutlineView* ?)(Object*)o).nativeExpandable(item);
    }
u8* xgGtkOutlineValue(pointer o, pointer item, i32 c)
    {
    return ((UXOutlineView* ?)(Object*)o).nativeItemValue(item, c);
    }
void xgGtkOutlineDidExpand(pointer o, pointer item, i32 on)
    {
    ((UXOutlineView* ?)(Object*)o).nativeDidExpand(item, on);
    }
i32 xgGtkOutlineIsExpanded(pointer o, pointer item)
    {
    return ((UXOutlineView* ?)(Object*)o).nativeIsItemExpanded(item);
    }
// The user's selection, made in the native view: into the model, announced, then a display pass.
void xgGtkTableSelectSet(pointer tbl, i32* rows, i32 n)
    {
    ((UXTableView* ?)(Object*)tbl).applyNativeSelection(rows, n);
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        }
    }

void ux_gtk_window_set_min_size(i32 handle, i32 w, i32 h);
void ux_gtk_set_text(i32 handle, i32 node, u8* text);
void ux_gtk_set_drop_hooks(pointer file, pointer item, pointer hover, pointer tableDrags, pointer outlineDragText);
pointer ux_gtk_outline_item_at(i32 handle, i32 node, i32 x, i32 y);
void ux_gtk_window_line(i32 handle, i32 on, i32 x0, i32 y0, i32 x1, i32 y1, i32 hx, i32 hy, i32 hw, i32 hh);
i32 ux_gtk_menu_popup(i32 handle, pointer titles, pointer flags, i32 n, i32 x, i32 y);
// Drops on a window and drags out of the app's tables and outlines, from the shim: to the app.
void xgGtkFileDrop(u8* path, i32 win, i32 x, i32 y)
    {
    if (gApp != (UXApplication*)0)
        {
        gApp.deliverFileDrop(path, win, x, y);
        }
    }
void xgGtkItemDrop(u8* item, i32 win, i32 x, i32 y)
    {
    if (gApp != (UXApplication*)0)
        {
        gApp.deliverItemDrop(item, win, x, y);
        }
    }
void xgGtkItemHover(u8* item, i32 win, i32 x, i32 y)
    {
    if (gApp != (UXApplication*)0)
        {
        gApp.deliverItemHover(item, win, x, y);
        }
    }
i32 xgGtkTableDrags(pointer tbl)
    {
    return ((UXTableView* ?)(Object*)tbl).nativeDragsRows();
    }
u8* xgGtkOutlineDragText(pointer o, pointer item, i32 unused)
    {
    return ((UXOutlineView* ?)(Object*)o).nativeDragText(item);
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
            ux_gtk_set_field_submit_hooks((pointer)&uxGtkFieldSubmitted);
            ux_gtk_textview_set_hooks((pointer)&uxGtkTextViewChanged, (pointer)&uxGtkTextViewSelected,
                                      (pointer)&uxGtkTextViewUndo);
            ux_gtk_set_mouse((pointer)&uxGtkDispatch);
            ux_gtk_set_scroll_content((pointer)&ux_scroll_draw); // a scroll document draws its subtree
            ux_gtk_set_table_hooks((pointer)&xgGtkTableRows, (pointer)&xgGtkTableCell, (pointer)&xgGtkTableCols,
                                   (pointer)&xgGtkTableColTitle, (pointer)&xgGtkTableColWidth,
                                   (pointer)&xgGtkTableMulti, (pointer)&xgGtkTableSelectSet);
            ux_gtk_set_outline_hooks((pointer)&xgGtkOutlineChildren, (pointer)&xgGtkOutlineChild,
                                     (pointer)&xgGtkOutlineExpandable, (pointer)&xgGtkOutlineValue,
                                     (pointer)&xgGtkOutlineDidExpand, (pointer)&xgGtkOutlineIsExpanded);
            ux_gtk_set_drop_hooks((pointer)&xgGtkFileDrop, (pointer)&xgGtkItemDrop, (pointer)&xgGtkItemHover,
                                  (pointer)&xgGtkTableDrags, (pointer)&xgGtkOutlineDragText);
            }
        return ux_gtk_boot(screenW, screenH) != (i32)0;
        }
    // ---- GL ------------------------------------------------------------------
    // A real GtkGLArea surface, made by the shim at realization.  The KIND is a property
    // of the backend: GTK4 on the desktop offers a core-profile context, and a machine or
    // a display that cannot give one makes GtkGLArea report an error, at which point
    // makeGLContext returns 0 and the view paints its drawRect fallback like any other.
    //
    // The shim keys its widgets by (window, node); the driver keys the OPAQUE view it is
    // handed by (window, node) too, because that pair is what the shim needs and the peer
    // alone does not carry it.  The peer only exists from makeGL on, so the binding is
    // taken on whichever realization arrives first with a non-null peer.
    pointer gGtkGlPeer[16];
    i32 gGtkGlHandle[16];
    i32 gGtkGlNode[16];
    i32 gGtkGlCount;

    void glBindPeer(pointer peer, i32 handle, i32 node)
        {
        if (peer == (pointer)0)
            {
            return;
            }
        for (i32 k = (i32)0; k < self.gGtkGlCount; k = k + (i32)1)
            {
            if (self.gGtkGlPeer[k] == peer)
                {
                return;
                }
            }
        if (self.gGtkGlCount >= (i32)16)
            {
            return;
            }
        self.gGtkGlPeer[self.gGtkGlCount] = peer;
        self.gGtkGlHandle[self.gGtkGlCount] = handle;
        self.gGtkGlNode[self.gGtkGlCount] = node;
        self.gGtkGlCount = self.gGtkGlCount + (i32)1;
        }
    i32 glSlot(pointer view)
        {
        for (i32 k = (i32)0; k < self.gGtkGlCount; k = k + (i32)1)
            {
            if (self.gGtkGlPeer[k] == view)
                {
                return k;
                }
            }
        return (i32)-1;
        }

    i32 glKind(void)
        {
        return (i32)UX_GL_GL33;
        }
    // GtkGLArea is an ordinary widget, composited with its siblings in one step.
    bool compositesWithGL(void)
        {
        return true;
        }
    pointer glProc(u8* name)
        {
        return ux_gtk_gl_proc(name);
        }
    pointer makeGLContext(pointer view)
        {
        i32 k = self.glSlot(view);
        if (k < (i32)0)
            {
            return (pointer)0; // no surface (unrealized, or the span was never realized)
            }
        if (ux_gtk_gl_make_current(self.gGtkGlHandle[k], self.gGtkGlNode[k]) == (i32)0)
            {
            return (pointer)0; // no GL context: the view keeps its drawRect fallback
            }
        ux_gtk_gl_viewport(self.gGtkGlHandle[k], self.gGtkGlNode[k]);
        return (pointer)(k + (i32)1); // the opaque token, never the toolkit's context
        }
    void destroyGLContext(pointer view)
        {
        // The GtkGLArea owns its context and frees it with the window, so there is nothing
        // to delete here; releasing the token is the whole of it (the app drops the pointer).
        }
    void resizeGL(pointer view, i32 w, i32 h)
        {
        i32 k = self.glSlot(view);
        if (k >= (i32)0)
            {
            ux_gtk_gl_viewport(self.gGtkGlHandle[k], self.gGtkGlNode[k]);
            }
        }
    void presentGL(pointer view)
        {
        i32 k = self.glSlot(view);
        if (k >= (i32)0)
            {
            ux_gtk_gl_present(self.gGtkGlHandle[k], self.gGtkGlNode[k]);
            }
        }
    void glSetSwapInterval(i32 interval)
        {
        // GTK paces the frame against the compositor and gives no interval seam; the VSync
        // the harness turns off is not something this backend can turn off either.
        }
    // a GL view's drawable and its last frame: the driver's own framebuffer, which keeps the frame
    i32 glDrawableSize(pointer view, i32* pw, i32* ph)
        {
        i32 k = self.glSlot(view);
        return k >= (i32)0 ? ux_gtk_gl_drawable(self.gGtkGlHandle[k], self.gGtkGlNode[k], pw, ph) : (i32)0;
        }
    i32 glReadFrame(pointer view, u32* out, i32 pw, i32 ph)
        {
        i32 k = self.glSlot(view);
        return k >= (i32)0 ? ux_gtk_gl_read(self.gGtkGlHandle[k], self.gGtkGlNode[k], out, pw, ph) : (i32)0;
        }

    // The frame clock: the neutral loop calls fn (its nextEvent takes the wait, so a turn
    // comes round with no input).  This driver has no turn of its own to offer -- it does
    // not own the loop -- so the answer is false and UXApplication paces itself.
    bool setTurnHook(turnHook_t* fn, i32 ms)
        {
        return false;
        }

    i32 formFactorClass(void)
        {
        return (i32)UX_FORM_DESKTOP;
        }
    // the desktop has no orientation axis
    i32 orientation(void)
        {
        return (i32)UX_ORIENT_NONE;
        }
    // desktop: the neutral loop pumps GTK
    bool driverOwnsRunLoop(void)
        {
        return false;
        }

    // the application's lifecycle (UXViewDriver): nothing to wire, stop or hide here
    void appAttached(pointer app)
        {
        }
    void requestStop(void)
        {
        }
    void setHeadless(bool on)
        {
        }
    bool stopAfterMs(i32 ms)
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
    // GTK 4 takes a window's icon only by NAME from the installed icon theme, so the app's icon
    // PulseAudio (or PipeWire's Pulse server), loaded at run time; false with no sound server.
    bool audioPlay(i16* pcm, i32 frames, i32 rate)
        {
        return ux_gtk_audio_play(pcm, frames, rate) != (i32)0;
        }
    // comes from its .desktop entry and the theme: packaging, not a call.
    bool appSetIcon(u8* data, i32 w, i32 h, i32 format)
        {
        return false;
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
    // the toplevel rendered through its paintable, GL area and native widgets included (libUXGtk.c)
    i32 windowSnapshot(i32 handle, i32 x, i32 y, i32 w, i32 h, u32* out)
        {
        return ux_gtk_window_snapshot(handle, x, y, w, h, out);
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
    // GTK 4's own dialogs: GtkFileDialog, GtkColorDialog, GtkFontDialog (libUXGtk.c)
    bool hasNativeFileOpen(void)
        {
        return true;
        }
    // no native save dialog here: UXSavePanel draws UXKit's own
    // no platform navigation stack here: UXNavigationController draws its own bar
    bool hasNativeNavigation(void)
        {
        return false;
        }
    pointer navAttach(i32 win, i32 navId, i32 x, i32 y, i32 w, i32 h)
        {
        return (pointer)0;
        }
    void navPush(pointer nav, u8* title, i32 animated)
        {
        }
    void navPop(pointer nav, i32 animated)
        {
        }
    bool hasNativeFileSave(void)
        {
        return true;
        }
    i32 fileSave(u8* prompt, u8* startDir, u8* defaultName, u8* out, i32 outCap)
        {
        return ux_gtk_file_save(prompt, startDir, defaultName, out, outCap);
        }
    i32 fileOpen(u8* prompt, u8* startDir, u8* out, i32 outCap)
        {
        return ux_gtk_file_open(prompt, startDir, out, outCap);
        }
    bool hasNativeColorPicker(void)
        {
        return true;
        }
    i32 pickColor(i32 r, i32 g, i32 b, i32* outR, i32* outG, i32* outB)
        {
        return ux_gtk_pick_color(r, g, b, outR, outG, outB);
        }
    bool hasNativeFontPicker(void)
        {
        return true;
        }
    i32 pickFont(u8* inFamily, i32 inSize, i32 inBold, i32 inItalic,
                 u8* outFamily, i32 outCap, i32* outSize, i32* outBold, i32* outItalic)
        {
        return ux_gtk_pick_font(inFamily, inSize, inBold, inItalic, outFamily, outCap, outSize, outBold, outItalic);
        }
    i32 listDir(u8* path, u8* out, i32 outCap)
        {
        return ux_posix_listdir(path, out, outCap);
        }
    i32 fileDelete(u8* path)
        {
        return ux_posix_delete(path);
        }
    i32 fileRename(u8* src, u8* dst)
        {
        return ux_posix_rename(src, dst);
        }
    i32 fileCopy(u8* src, u8* dst)
        {
        return ux_posix_copy(src, dst);
        }

    // ---- time / settings / measurement ---------------------------------------
    i32 nowMs(void)
        {
        return ux_gtk_now_ms();
        }
    // The fine clock is the coarse one in microseconds: this backend's clock has no more
    // resolution than a millisecond, and inventing bits that are not there would make a
    // frame-time measurement look precise on a backend where it is not.
    i32 nowUs(void)
        {
        return ux_gtk_now_ms() * (i32)1000;
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
        return self.textWidthWeight(s, family, size,
                                    bold ? (i32)UXWEIGHT_SEMIBOLD : (i32)UXWEIGHT_NORMAL, italic);
        }
    i32 textWidthWeight(u8* s, u8* family, i32 size, i32 weight, bool italic)
        {
        return ux_gtk_text_width_weight(s, family, size, weight, italic ? (i32)1 : (i32)0);
        }
    i32 textAscent(u8* family, i32 size, i32 weight, bool italic)
        {
        return ux_gtk_text_ascent(family, size, weight, italic ? (i32)1 : (i32)0);
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
        n.clipR = (i16)0;
        n.clipIn = (i16)0;
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
        while (guard <= (i32)4096)
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
        while (cur >= (i32)0 && guard <= (i32)4096)
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
    void structSetClipShape(pointer h, i32 i, i32 radius, i32 inset)
        {
        ((GKTree*)h).nodes[i].clipR = (i16)radius;
        ((GKTree*)h).nodes[i].clipIn = (i16)inset;
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
    void windowSetMinSize(i32 handle, i32 w, i32 h)
        {
        ux_gtk_window_set_min_size(handle, w, h);
        }
    // a drawing area over the content that takes no input
    void windowLine(i32 handle, i32 on, i32 x0, i32 y0, i32 x1, i32 y1, i32 hx, i32 hy, i32 hw, i32 hh)
        {
        ux_gtk_window_line(handle, on, x0, y0, x1, y1, hx, hy, hw, hh);
        }
    pointer outlineItemAt(i32 handle, i32 node, i32 x, i32 y)
        {
        return ux_gtk_outline_item_at(handle, node, x, y);
        }
    // a popover of buttons, run until it closes
    i32 menuPopUp(i32 handle, pointer titles, pointer flags, i32 n, i32 x, i32 y)
        {
        return ux_gtk_menu_popup(handle, titles, flags, n, x, y);
        }
    // ---- the native text view (UXTextView); the undo is the view's own --------------------------
    void textViewSetAll(i32 handle, i32 node, u8* text, i32 nbytes, i32* runs, i32 nruns)
        {
        ux_gtk_textview_set_all(handle, node, text, nbytes, runs, nruns);
        }
    void textViewReplace(i32 handle, i32 node, i32 start, i32 len, u8* text, i32 nbytes, i32* runs, i32 nruns,
                         i32 attrsOnly)
        {
        ux_gtk_textview_replace(handle, node, start, len, text, nbytes, runs, nruns, attrsOnly);
        }
    void textViewSize(i32 handle, i32 node, i32* nbytes, i32* nruns)
        {
        ux_gtk_textview_size(handle, node, nbytes, nruns);
        }
    i32 textViewRead(i32 handle, i32 node, u8* buf, i32 cap, i32* runs, i32 maxRuns)
        {
        return ux_gtk_textview_read(handle, node, buf, cap, runs, maxRuns);
        }
    void textViewSelection(i32 handle, i32 node, i32* start, i32* len)
        {
        ux_gtk_textview_selection(handle, node, start, len);
        }
    void textViewSetSelection(i32 handle, i32 node, i32 start, i32 len)
        {
        ux_gtk_textview_set_selection(handle, node, start, len);
        }
    void textViewSetTyping(i32 handle, i32 node, i32 flags, i32 colour, i32 size)
        {
        ux_gtk_textview_set_typing(handle, node, flags, colour, size);
        }
    void textViewFocus(i32 handle, i32 node)
        {
        ux_gtk_textview_focus(handle, node);
        }
    void textViewSetLook(i32 handle, i32 node, i32 background, i32 ink, i32 caret, i32 selection, i32 size,
                         i32 monospace)
        {
        ux_gtk_textview_set_look(handle, node, background, ink, caret, selection, size, monospace);
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
    void pushValue(i32 handle, i32 i, i32 kind, pointer peer)
        {
        Object* o = (Object*)peer;
        if (o == (Object*)0)
            {
            return;
            }
        if (kind == (i32)UXKindSlider)
            {
            UXSlider* sl = (UXSlider* ?)o;
            if (sl != (UXSlider*)0)
                {
                ux_gtk_set_slider_value(handle, i, sl.nativeValue());
                }
            }
        else if (kind == (i32)UXKindStepper)
            {
            UXStepper* st = (UXStepper* ?)o;
            if (st != (UXStepper*)0)
                {
                ux_gtk_set_stepper_value(handle, i, st.nativeValue());
                }
            }
        else if (kind == (i32)UXKindProgress)
            {
            UXProgressBar* pg = (UXProgressBar* ?)o;
            if (pg != (UXProgressBar*)0)
                {
                ux_gtk_set_progress(handle, i, pg.nativeFractionMille(), pg.nativeIndeterminate());
                }
            }
        else if (kind == (i32)UXKindSegmented)
            {
            UXSegmentedControl* sg = (UXSegmentedControl* ?)o;
            if (sg != (UXSegmentedControl*)0 && sg.nativeMultiSelect() == (i32)0)
                {
                ux_gtk_seg_select(handle, i, sg.nativeSelectedSeg());
                }
            }
        else if (kind == (i32)UXKindPopup)
            {
            UXPopUpButton* pb = (UXPopUpButton* ?)o;
            if (pb != (UXPopUpButton*)0)
                {
                ux_gtk_popup_select(handle, i, pb.nativeSelected());
                }
            }
        }
    i32 alignOf(pointer peer)
        {
        UXControl* c = (UXControl* ?)(Object*)peer;
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
            UXCheckbox* cb = (UXCheckbox* ?)(Object*)peer;
            if (cb != (UXCheckbox*)0 && cb.isChecked())
                {
                return (i32)1;
                }
            }
        else
            {
            UXRadioButton* rb = (UXRadioButton* ?)(Object*)peer;
            if (rb != (UXRadioButton*)0 && rb.isSelected())
                {
                return (i32)1;
                }
            }
        return (i32)0;
        }

    i32 isUnderTable(GKTree* t, i32 i)
        {
        i16 p = t.nodes[i].parent;
        while (p >= (i16)0)
            {
            if ((i32)t.nodes[p].kind == (i32)UXKindTable)
                {
                if ((UXTableView* ?)(Object*)t.nodes[p].peer != (UXTableView*)0)
                    {
                    return (i32)1;
                    }
                }
            p = t.nodes[p].parent;
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
            // A native table covers its whole subtree (rows, cells, its own scroller): none of
            // that becomes a native widget of its own.
            if (self.isUnderTable(t, i) != (i32)0)
                {
                continue;
                }
            if ((i32)n.kind == (i32)UXKindTable)
                {
                UXTableView* tv = (UXTableView* ?)(Object*)n.peer;
                if (tv == (UXTableView*)0)
                    {
                    continue;
                    }
                bool outline = tv.nativeIsOutline() != (i32)0; // a tree vs a flat list
                if (ux_gtk_has_control(handle, i) == (i32)0)
                    {
                    if (outline)
                        {
                        ux_gtk_make_outline(handle, i, ax, ay, aw, ah, n.peer);
                        }
                    else
                        {
                        ux_gtk_make_table(handle, i, ax, ay, aw, ah, n.peer);
                        }
                    }
                else
                    {
                    ux_gtk_set_control_frame(handle, i, ax, ay, aw, ah);
                    if (outline)
                        {
                        ux_gtk_outline_reload(handle, i);
                        }
                    else
                        {
                        ux_gtk_table_reload(handle, i);
                        }
                    }
                // a selection the MODEL made (app code, a replay) goes the other way: the view is the
                // visible truth and never reads the model back
                if (tv.nativeSelectionNeedsPush())
                    {
                    i32 rows[256];
                    i32 nsel = tv.selectedRowList(&rows[(i32)0], (i32)256);
                    ux_gtk_table_select(handle, i, &rows[(i32)0], nsel);
                    tv.clearNativeSelectionPush();
                    }
                ux_gtk_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                continue;
                }
            if ((i32)n.kind == (i32)UXKindScroll)
                {
                // A GtkScrolledWindow over the scroll view; its document draws the scroll view's
                // document subtree (ux_scroll_draw), at the document's own place in the window.
                UXScrollView* sv = (UXScrollView* ?)(Object*)n.peer;
                if (sv == (UXScrollView*)0)
                    {
                    continue;
                    }
                i32 dn = sv.nativeDocNode();
                i32 dx = ax;
                i32 dy = ay;
                if (dn >= (i32)0)
                    {
                    i32 dw = (i32)0;
                    i32 dh = (i32)0;
                    self.structAbsFrame(tree, dn, &dx, &dy, &dw, &dh);
                    }
                if (ux_gtk_has_control(handle, i) == (i32)0)
                    {
                    ux_gtk_make_scroll(handle, i, ax, ay, aw, ah, sv.nativeContentHeight(), n.peer, dx, dy);
                    }
                else
                    {
                    ux_gtk_set_control_frame(handle, i, ax, ay, aw, ah);
                    ux_gtk_scroll_reload(handle, i, aw, ah, sv.nativeContentHeight(), dx, dy);
                    }
                ux_gtk_scroll_style(handle, i, sv.nativeCornerRadius(), sv.nativeBorderRGB());
                ux_gtk_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                continue;
                }
            if ((i32)n.kind == (i32)UXKindShield)
                {
                ux_gtk_make_shield(handle, ax, ay, aw, ah, self.effectiveHidden(tree, i));
                continue;
                }
            if ((i32)n.kind == (i32)UXKindGLView)
                {
                // The SURFACE, made with the tree and not before.  It sits BELOW the cairo
                // drawing area, so the toolkit's 2D paints over the map.  The context is not
                // made here -- that is makeGLContext's job -- and the peer that makeGLContext
                // is handed only exists from makeGL on, so the slot is bound on every pass.
                ux_gtk_make_gl(handle, i, ax, ay, aw, ah, self.effectiveHidden(tree, i));
                self.glBindPeer(n.peer, handle, i);
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
                // ...and the other values, for the same reason (a slider the app moves, progress
                // advancing, a selection the app makes); each setter leaves an equal value alone
                // and does not report its own change back
                self.pushValue(handle, i, (i32)n.kind, n.peer);
                // ...and the text: a button's, label's or toggle's title changed since it was made
                if (((i32)n.kind == (i32)UXKindButton || (i32)n.kind == (i32)UXKindLabel ||
                     (i32)n.kind == (i32)UXKindCheckbox || (i32)n.kind == (i32)UXKindRadio) && n.spec != (pointer)0)
                    {
                    ux_gtk_set_text(handle, i, (u8*)n.spec);
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
                gGtkCtlPeer[handle * (i32)4096 + i] = n.peer;
                }
            else if (n.kind == (i32)UXKindLabel && n.spec != (pointer)0)
                {
                ux_gtk_make_label(handle, i, ax, ay, aw, ah, (u8*)n.spec);
                }
            else if (n.kind == (i32)UXKindTextView)
                {
                UXTextView* tvp = (UXTextView* ?)(Object*)n.peer;
                if (tvp != (UXTextView*)0)
                    {
                    ux_gtk_make_textview(handle, i, ax, ay, aw, ah);
                    gGtkCtlPeer[handle * (i32)4096 + i] = n.peer;
                    tvp.nativeAttach(handle, i);
                    }
                }
            else if (n.kind == (i32)UXKindField)
                {
                GKField* f = (GKField*)n.spec;
                if (f != (GKField*)0)
                    {
                    ux_gtk_make_field(handle, i, ax, ay, aw, ah, f.buf, f.cap, f.secure);
                    gGtkCtlPeer[handle * (i32)4096 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindCheckbox || n.kind == (i32)UXKindRadio)
                {
                // The platform's toggle idiom IS the switch — checked state
                // from the peer, exactly the mac driver's toggleState read.
                // Cast through Object*: a checked cast from a raw pointer is NOT checked (it always
                // succeeds), so a check box's peer would pass as a radio and the reverse.
                UXCheckbox* cb = (UXCheckbox* ?)(Object*)n.peer;
                if (cb != (UXCheckbox*)0)
                    {
                    u8* title = n.spec != (pointer)0 ? (u8*)n.spec : (u8*)"";
                    ux_gtk_make_check(handle, i, ax, ay, aw, ah, title,
                                      cb.isChecked() ? (i32)1 : (i32)0);
                    gGtkCtlPeer[handle * (i32)4096 + i] = n.peer;
                    }
                // A radio is a GtkCheckButton in a GROUP, which GTK draws round: grouped with the
                // first button of its UXRadioGroup in this tree (the group's exclusion stays neutral,
                // and every display pushes each button's state).
                UXRadioButton* rbn = (UXRadioButton* ?)(Object*)n.peer;
                if (rbn != (UXRadioButton*)0)
                    {
                    u8* title = n.spec != (pointer)0 ? (u8*)n.spec : (u8*)"";
                    i32 leader = (i32)-1;
                    if (rbn.group != (UXRadioGroup*)0 && rbn.group.buttons.count() > (u16)0)
                        {
                        UXRadioButton* first = (UXRadioButton* ?)rbn.group.buttons.get((u16)0);
                        if (first != (UXRadioButton*)0 && first != rbn && first.owner == rbn.owner)
                            {
                            leader = (i32)first.index;
                            }
                        }
                    ux_gtk_make_radio(handle, i, ax, ay, aw, ah, title, rbn.isSelected() ? (i32)1 : (i32)0, leader);
                    gGtkCtlPeer[handle * (i32)4096 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindSlider)
                {
                UXSlider* sv = (UXSlider* ?)(Object*)n.peer;
                if (sv != (UXSlider*)0)
                    {
                    ux_gtk_make_slider(handle, i, ax, ay, aw, ah,
                                       sv.nativeMin(), sv.nativeMax(), sv.nativeValue());
                    gGtkCtlPeer[handle * (i32)4096 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindStepper)
                {
                UXStepper* sv = (UXStepper* ?)(Object*)n.peer;
                if (sv != (UXStepper*)0)
                    {
                    ux_gtk_make_stepper(handle, i, ax, ay, aw, ah,
                                        sv.nativeMin(), sv.nativeMax(), sv.nativeStep(),
                                        sv.nativeWraps() ? (i32)1 : (i32)0, sv.nativeValue());
                    gGtkCtlPeer[handle * (i32)4096 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindProgress)
                {
                UXProgressBar* pgv = (UXProgressBar* ?)(Object*)n.peer;
                if (pgv != (UXProgressBar*)0)
                    {
                    ux_gtk_make_progress(handle, i, ax, ay, aw, ah, pgv.nativeFractionMille());
                    gGtkCtlPeer[handle * (i32)4096 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindPopup)
                {
                UXPopUpButton* pv = (UXPopUpButton* ?)(Object*)n.peer;
                if (pv != (UXPopUpButton*)0)
                    {
                    ux_gtk_make_popup(handle, i, ax, ay, aw, ah);
                    for (i32 j = (i32)0; j < pv.nativeItemCount(); j = j + (i32)1)
                        {
                        ux_gtk_popup_add_item(handle, i, pv.nativeItemTitle(j));
                        }
                    ux_gtk_popup_select(handle, i, pv.nativeSelected());
                    gGtkCtlPeer[handle * (i32)4096 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindSegmented)
                {
                UXSegmentedControl* gv = (UXSegmentedControl* ?)(Object*)n.peer;
                if (gv != (UXSegmentedControl*)0)
                    {
                    ux_gtk_make_segmented(handle, i, ax, ay, aw, ah, gv.nativeSegCount());
                    for (i32 j = (i32)0; j < gv.nativeSegCount(); j = j + (i32)1)
                        {
                        ux_gtk_seg_set_label(handle, i, j, gv.nativeSegLabel(j));
                        }
                    ux_gtk_seg_select(handle, i, gv.nativeSelectedSeg());
                    gGtkCtlPeer[handle * (i32)4096 + i] = n.peer;
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
        // A native control inside a scroll view goes into that container's document, so it scrolls
        // and clips with it (as AppKit's go into the NSScrollView's document view).  A scroll, a
        // table or a GL view owns its own surface and stays where it is.
        for (i32 i = (i32)0; i < t.count; i = i + (i32)1)
            {
            i32 kk = (i32)t.nodes[i].kind;
            if (kk == (i32)UXKindScroll || kk == (i32)UXKindTable || kk == (i32)UXKindGLView || ux_gtk_has_control(handle, i) == (i32)0)
                {
                continue;
                }
            i32 anc = (i32)t.nodes[i].parent;
            while (anc >= (i32)0)
                {
                if ((i32)t.nodes[anc].kind == (i32)UXKindScroll && ux_gtk_has_control(handle, anc) != (i32)0)
                    {
                    i32 cx = (i32)0;
                    i32 cy = (i32)0;
                    i32 cw = (i32)0;
                    i32 chh = (i32)0;
                    self.structAbsFrame(tree, i, &cx, &cy, &cw, &chh);
                    ux_gtk_reparent_to_scroll(handle, i, anc, cx, cy);
                    break;
                    }
                anc = (i32)t.nodes[anc].parent;
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
        // ...and a native table paints its whole subtree: its rows are the GtkColumnView's.
        if (native && (k == (i32)UXKindTable || k == (i32)UXKindScroll))
            {
            return; // ...as a native scroll container's document paints its own (ux_scroll_draw)
            }
        if (!native)
            {
            // The GEM rule: every non-native node is app-drawn through the
            // userdraw seam — View AND the custom-drawn controls.  (Same gap,
            // same fix as the web driver; the capture pipeline found it.)
            if (gGtkUserFn != (pointer)0)
                {
                // A view's drawing stays INSIDE ITS FRAME, as an NSView's does.
                i32 vx = (i32)0;
                i32 vy = (i32)0;
                i32 vw = (i32)0;
                i32 vh = (i32)0;
                self.structAbsFrame((pointer)t, i, &vx, &vy, &vw, &vh);
                ux_gtk_clip(vx - gGtkDrawOX, vy - gGtkDrawOY, vw, vh); // in the surface's own space
                UXGtkUserDrawFn* f = (UXGtkUserDrawFn*)gGtkUserFn;
                f((pointer)t.nodes, i, gGtkUserUd);
                ux_gtk_clip_end();
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
            i32 ci = (i32)t.nodes[i].clipIn;
            ux_gtk_clip_round(cx + ci - gGtkDrawOX, cy + ci - gGtkDrawOY, cw - ci * (i32)2, chh - ci * (i32)2, (i32)t.nodes[i].clipR);
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
    // the view is clipped to its frame by this driver's own tree walk
    void endViewDraw(void)
        {
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
    // A scroll view is a GtkScrolledWindow, which owns the offset (realizeTree)
    bool scrollsNatively(void)
        {
        return true;
        }
    void nativeScrollTo(pointer h, i32 node, i32 px)
        {
        ux_gtk_scroll_set(((GKTree*)h).win, node, px);
        }
    i32 nativeScrollPx(pointer h, i32 node)
        {
        return ux_gtk_scroll_get(((GKTree*)h).win, node);
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
    // A real GtkPopoverMenuBar over a GMenu, one action per item (see libUXGtk.c).  Item ids ARE
    // ordinals, as on AppKit: the shim's pick reports (title, item) directly.
    pointer menuBuild(pointer defs, i32 n, i32 screenW)
        {
        UXMenuDef* d = (UXMenuDef*)defs;
        pointer bar = ux_gtk_menu_new();
        for (i32 t = (i32)0; t < n; t = t + (i32)1)
            {
            i32 ti = ux_gtk_menu_add_title(bar, d[t].title);
            u8** items = d[t].items;
            for (i32 j = (i32)0; j < d[t].nitems; j = j + (i32)1)
                {
                u8* s = items[j];
                if (s[0] == (u8)45 && s[1] == (u8)0) // "-": a separator
                    {
                    ux_gtk_menu_add_item(bar, ti, j, (u8*)"", (i32)0, (i32)0, (i32)1);
                    }
                else if (s[0] == (u8)1) // pre-ticked
                    {
                    ux_gtk_menu_add_item(bar, ti, j, &s[1], (i32)1, (i32)0, (i32)0);
                    }
                else if (s[0] == (u8)2) // disabled
                    {
                    ux_gtk_menu_add_item(bar, ti, j, &s[1], (i32)0, (i32)1, (i32)0);
                    }
                else
                    {
                    ux_gtk_menu_add_item(bar, ti, j, s, (i32)0, (i32)0, (i32)0);
                    }
                }
            }
        return bar;
        }
    void menuShow(pointer menu, i32 show)
        {
        ux_gtk_menu_show(menu, show);
        }
    i32 menuItemOrd(pointer menu, i32 titleOrd, i32 itemObj)
        {
        return itemObj;
        }
    void menuCheck(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
        {
        ux_gtk_menu_check(titleOrd, itemOrd, on);
        }
    void menuEnable(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
        {
        ux_gtk_menu_enable(titleOrd, itemOrd, on);
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
        // A frame clock turns the wait into a deadline: wait_event_ms returns on the deadline
        // when no input does, so the neutral loop's turn comes round.  0 = the old blocking wait.
        ux_gtk_wait_event_ms(timeoutMs);
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
    // a view may loop on trackDragStep inside its mouseDown
    bool dragTrackingIsModal(void)
        {
        return true;
        }
    i32 trackDragStep(i32* x, i32* y)
        {
        // see gInputReplay (UXEvent.xc)
        if (gInputReplay)
            {
            return (i32)0;
            }
        i32 r = ux_gtk_drag_next(x, y);
        x[0] = x[0] + gUXDragDX; // in the press's terms: a drag that began on a scrolled document
        y[0] = y[0] + gUXDragDY;
        return r;
        }

    i32 liveNativeCount(void)
        {
        return ux_gtk_native_count();
        }
    }
