// UXAndroidDriver.xc — the Android realization of UXViewDriver: the seventh
// backend, iOS's device-realm sibling.  The founding pattern holds — USE THE
// NATIVE UI — and here that means real android.widget views built over JNI
// (libUXAndroid.c), with the ONE Java class the platform forces (the listener
// bridge) carried as a committed bootstrap dex (tools/android/, spike-proven).
//
// The run loop is the iOS B + A shape with the thread hop made explicit:
// the framework's UI thread owns the loop; the compiler's glue runs xt_main
// on a detached thread; runLoop() posts the app's start onto the UI thread
// (the dex's UXRun) and parks.  boot(), windows, realizeTree, painting and
// firing all happen UI-side, inside the posted entry or a widget callback.
//
// Bring-up state (the android-real gate): windows as FrameLayouts, the
// shadow tree, custom-view painting through Canvas (UXAndroidGraphics),
// native Button/TextView overlays via realizeTree, the fire-by-peer action
// path (OnClickListener -> UXBridge -> nativeFire), time/measurement, the
// offscreen Bitmap readback rig.  Deliberately stubbed, each with its
// milestone: the value controls (Switch/SeekBar/ProgressBar/Spinner), the
// EditText overlay, menus, alerts (AlertDialog), scrolling (ScrollView),
// SharedPreferences settings, Typeface-styled measurement.
#import "UXViewDriver.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXAndroidGraphics.xc"
#import "UXEvent.xc"
#import "UXControl.xc"
#import "UXSlider.xc"      // native SeekBar overlay reads/writes this widget's value
#import "UXStepper.xc"     // composed -/+ Button pair (Android has no platform stepper)
#import "UXSegmentedControl.xc" // composed of native ToggleButtons (nor a segmented control)
#import "UXToolbar.xc"          // a real android.widget.Toolbar
#import "UXPopUpButton.xc" // native Spinner overlay
#import "UXProgressBar.xc" // native horizontal ProgressBar overlay
#import "UXTouch.xc"              // drawn content's touches -> mouse events
#import "UXNavigationController.xc" // Up / Back on the native bar come back through uxNavNativePopped
#import "UXTableView.xc"   // the native table (a ListView) reads its rows from the peer table
#import "UXScrollView.xc"  // a scroll view is a ScrollView
#import "UXMenuEncode.xc"  // the app's menus, handed to the overflow button as one string
#import "UXApplication.xc" // gApp: the driver-owned loop starts the delegate, and stop() quits
#import "UXLibc.xc"
#import "UXFileIO.xc"         // the save panel's sink: a write to its path is copied on to the chosen document

// The shim (libUXAndroid.c).  Primitive signatures only — no jobject crosses into xtc.
i32 ux_and_boot(i32* w, i32* h);
i32 ux_and_alert(i32 icon, u8* lines, u8* buttons, i32 defBtn);
i32 ux_and_form_factor(void);
i32 ux_and_orientation(void); // 1 portrait, 2 landscape
pointer ux_and_nav_attach(i32 win, i32 navId, i32 x, i32 y, i32 w, i32 h);
void ux_and_nav_push(pointer nav, u8* title, i32 animated);
void ux_and_nav_pop(pointer nav, i32 animated);
void ux_and_set_nav_popped(pointer fn);
void ux_and_set_touch(pointer fn);
// native scroll containers: a ScrollView whose document draws the scroll view's subtree
void ux_and_set_scroll_content(pointer fn);
void ux_and_make_scroll(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 contentH, pointer sv, i32 docX, i32 docY);
void ux_and_scroll_reload(i32 handle, i32 node, i32 w, i32 h, i32 contentH, i32 docX, i32 docY);
void ux_and_scroll_set(i32 handle, i32 node, i32 px);
i32 ux_and_scroll_get(i32 handle, i32 node);
void ux_and_scroll_style(i32 handle, i32 node, i32 radius, i32 rgb);
void ux_and_reparent_to_scroll(i32 handle, i32 node, i32 scrollNode, i32 ax, i32 ay, i32 aw, i32 ah);
// The native table (UXTable: a ListView under a header), fed by the peer UXTableView through hooks.
void ux_and_set_table_hooks(pointer rows, pointer cell, pointer cols, pointer title, pointer width, pointer multi, pointer selset);
void ux_and_make_table(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, pointer peer, i32 outline);
void ux_and_set_outline_hooks(pointer level, pointer disclosure, pointer toggle);
// The app's menus, from an overflow button (UXMenuEncode's string); a pick comes back as (title, item).
void ux_and_set_menu_pick(pointer fn);
void ux_and_menu_set(u8* enc);
void ux_and_menu_state(i32 t, i32 j, i32 what, i32 on);
// GL (GLES 3, offscreen): entry points, a context per view, its resize, present and paint.
pointer ux_and_gl_proc(u8* name);
pointer ux_and_gl_make(pointer view, i32 w, i32 h);
void ux_and_gl_resize(pointer view, i32 w, i32 h);
void ux_and_gl_destroy(pointer view);
void ux_and_gl_present(pointer view);
i32 ux_and_gl_paint(pointer view, i32 win, i32 x, i32 y, i32 w, i32 h);
// The system document picker; the picked document is copied into the cache and its path given.
i32 ux_and_file_open(u8* out, i32 cap);
i32 ux_and_window_snapshot(i32 handle, i32 x, i32 y, i32 w, i32 h, u32* out);
// ACTION_CREATE_DOCUMENT for the save panel, and the copy on to the document after a write.
i32 ux_and_file_save(u8* defaultName, u8* out, i32 cap);
i32 ux_and_file_written(u8* path);
void ux_and_table_reload(i32 handle, i32 node);
void ux_and_table_select(i32 handle, i32 node, i32* rows, i32 n);
i32 ux_and_window_create(i32 x, i32 y, i32 w, i32 h);
void ux_and_window_set_content(i32 handle, pointer fn, pointer ud);
void ux_and_window_open(i32 handle, i32 x, i32 y, i32 w, i32 h);
void ux_and_window_front(i32 handle);
void ux_and_window_close(i32 handle);
void ux_and_window_invalidate(i32 handle);
void ux_and_content_geometry(i32 handle, i32* w, i32* h);
i32 ux_and_native_count(void);
i32 ux_and_has_control(i32 handle, i32 node);
void ux_and_make_button(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* title);
void ux_and_make_label(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* text);
void ux_and_make_checkbox(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* title, i32 on);
void ux_and_make_radio(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* title, i32 on);
void ux_and_set_checkbox(i32 handle, i32 node, i32 on);
void ux_and_make_slider(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 lo, i32 hi, i32 val);
void ux_and_set_slider_value(i32 handle, i32 node, i32 val);
void ux_and_make_shield(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 hidden);
i32 ux_and_gl_drawable(pointer view, i32* pw, i32* ph);
i32 ux_and_gl_read(pointer view, u32* out, i32 pw, i32 ph);
void ux_and_raise_shield(i32 handle);
void ux_and_make_progress(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 mille);
void ux_and_set_progress(i32 handle, i32 node, i32 mille, i32 indeterminate);
void ux_and_make_popup(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h);
void ux_and_popup_add_item(i32 handle, i32 node, u8* title);
void ux_and_popup_select(i32 handle, i32 node, i32 i);
void ux_and_make_field(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* buf, i32 cap, i32 secure);
void ux_and_make_stepper(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h);
// the segmented control, composed of native ToggleButtons (Android has no platform one)
void ux_and_make_segmented(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 nseg, i32 multi);
void ux_and_seg_set_label(i32 handle, i32 node, i32 seg, u8* label);
void ux_and_seg_set(i32 handle, i32 node, i32 seg, i32 on);
// the toolbar: a real android.widget.Toolbar; type is UXTB_ITEM / SPACE / FLEX / SEP
void ux_and_make_toolbar(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h);
void ux_and_toolbar_add(i32 handle, i32 node, i32 type, u8* label, i32 tag);
void ux_and_update_field(i32 handle, i32 node);
void ux_and_set_control_frame(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h);
void ux_and_set_control_enabled(i32 handle, i32 node, i32 on);
void ux_and_set_control_hidden(i32 handle, i32 node, i32 on);
void ux_and_set_control_fire(pointer fn);
void ux_and_set_value_changed(pointer fn);
void ux_and_set_field_hooks(pointer fn);
void ux_and_set_field_submit_hooks(pointer fn);
void ux_and_set_entry(pointer fn);
void ux_and_set_turn_hook(pointer fn, i32 ms);
void ux_and_shell_run(void);
void ux_and_quit(i32 rc);
void ux_and_clip(i32 x, i32 y, i32 w, i32 h);
void ux_and_clip_end(void);
void ux_and_clip_round(i32 x, i32 y, i32 w, i32 h, i32 r); // ...with rounded corners
i32 ux_and_text_width(u8* s, i32 size);
i32 ux_and_text_width_font(u8* s, u8* family, i32 size, i32 bold, i32 italic);
i32 ux_and_text_width_weight(u8* s, u8* family, i32 size, i32 weight, i32 italic);
i32 ux_and_text_ascent(u8* family, i32 size, i32 weight, i32 italic);
i32 ux_and_now_ms(void);
void ux_and_now_utc(i32* out7);
i32 ux_and_local_offset_minutes(void);
i32 ux_and_setting_get(u8* domain, u8* key, u8* out, i32 cap);
i32 ux_and_setting_set(u8* domain, u8* key, u8* value);
i32 ux_and_setting_remove(u8* domain, u8* key);

// The draw-seam callbacks (§4 rule: these signatures ARE the ABI).
typedef i32 UXAndUserDrawFn(pointer tree, i32 obj, pointer ud);

// ── the shadow tree (the shared shape: Win32/AppKit/web/iOS/GTK) ────────────
struct ANNode
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
    } struct ANTree
    {
    ANNode* nodes;
    i32 count;
    i32 cap;
    i32 win;
    }

    struct ANField
    {
    u8* buf;
    i32 cap;
    u8* valid;
    u8* place;
    i32 secure;
    }

    // ── driver state ────────────────────────────────────────────────────────────
    UXAndroidGraphics* gAndGfx;
i32 gAndDrawOX;
i32 gAndDrawOY;
pointer gAndUserFn;
pointer gAndUserUd;
ANTree* gAndDrawTree;

// A native control was tapped: fire its neutral widget's action directly, by
// (handle, node) — the fire-by-peer pattern, verbatim.
pointer gAndCtlPeer[16384]; // [handle*256 + node] -> the control's neutral widget
UXEvent* gAndClickEvent;
// The driver-owned loop's start moment: the posted UXRun(0) lands here, and
// the neutral delegate starts exactly where the desktop loop would have.
// The user pressed Up or Back: the model pops, then the display pass every native event ends with
// (it is what un-hides the revealed form's widgets).
void uxAndNavPopped(i32 navId)
    {
    uxNavNativePopped(navId);
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        }
    }
void uxAndShellStart(void)
    {
    if (gApp != (UXApplication*)0)
        {
        gApp.startDelegate();
        }
    }
// A native value control moved: adopt the number into the peer, fire its
// action — the mac/iOS xgValueChanged pattern, Android edition (a CheckBox
// click reports its new state here rather than through the fire path).
// Table-data trampolines for the native table: the shim calls these with the peer UXTableView.
i32 xgAndTableRows(pointer tbl)
    {
    return ((UXTableView* ?)(Object*)tbl).nativeRowCount();
    }
u8* xgAndTableCell(pointer tbl, i32 r, i32 c)
    {
    return ((UXTableView* ?)(Object*)tbl).nativeCellText(r, c);
    }
i32 xgAndTableCols(pointer tbl)
    {
    return ((UXTableView* ?)(Object*)tbl).numberOfColumns();
    }
u8* xgAndTableColTitle(pointer tbl, i32 c)
    {
    return ((UXTableView* ?)(Object*)tbl).columnTitle(c);
    }
i32 xgAndTableColWidth(pointer tbl, i32 c)
    {
    return (i32)((UXTableView* ?)(Object*)tbl).columnWidth(c);
    }
i32 xgAndTableMulti(pointer tbl)
    {
    return ((UXTableView* ?)(Object*)tbl).nativeAllowsMultiple();
    }
// A pick from the overflow button's menu: the same event a desktop's menu bar sends (a = the
// title's object number, title + 2, as handleSelection expects; b = the item).
UXEvent* gAndMenuEvent;
void xgAndMenuPick(i32 t, i32 j)
    {
    if (gApp == (UXApplication*)0)
        {
        return;
        }
    if (gAndMenuEvent == (UXEvent*)0)
        {
        gAndMenuEvent = new UXEvent();
        }
    gAndMenuEvent.init();
    gAndMenuEvent.kind = (u8)UXEventMenuSelect;
    gAndMenuEvent.a = t + (i32)2;
    gAndMenuEvent.b = j;
    gApp.dispatchEvent(gAndMenuEvent);
    gApp.displayIfNeeded();
    }
// An outline's rows: depth, disclosure (bit 0 can open, bit 1 open), and an arrow tap.
i32 xgAndTableLevel(pointer tbl, i32 r)
    {
    return ((UXTableView* ?)(Object*)tbl).nativeRowLevel(r);
    }
i32 xgAndTableDisclosure(pointer tbl, i32 r)
    {
    return ((UXTableView* ?)(Object*)tbl).nativeRowDisclosure(r);
    }
void xgAndTableToggle(pointer tbl, i32 r)
    {
    ((UXTableView* ?)(Object*)tbl).nativeToggleRow(r);
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        }
    }
// A tap in the native table: the selection into the model, announced, then a display pass.
void xgAndTableSelectSet(pointer tbl, i32* rows, i32 n)
    {
    ((UXTableView* ?)(Object*)tbl).applyNativeSelection(rows, n);
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        }
    }
// the selection each native popup shows, plus one (0: not pushed yet)
i32 gAndPopupShown[16384];
void uxAndValueChanged(i32 handle, i32 node, i32 value)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)256)
        {
        return;
        }
    UXControl* ctl = (UXControl* ?)(Object*)gAndCtlPeer[handle * (i32)256 + node];
    if (ctl == (UXControl*)0)
        {
        return;
        }
    UXCheckbox* cb = (UXCheckbox* ?)ctl;
    if (cb != (UXCheckbox*)0)
        {
        cb.setChecked(value != (i32)0);
        }
    UXRadioButton* rb = (UXRadioButton* ?)ctl;
    if (rb != (UXRadioButton*)0 && value != (i32)0)
        {
        // exclusivity is NEUTRAL: the group clears the others, and the
        // has-control re-push below mirrors that back into every native
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
    UXPopUpButton* pu = (UXPopUpButton* ?)ctl;
    if (pu != (UXPopUpButton*)0 && value == pu.nativeSelected())
        {
        return; // a Spinner reporting the selection the model already has (a programmatic one): no pick
        }
    if (pu != (UXPopUpButton*)0)
        {
        pu.applyNativeSelection(value);
        }
    UXSegmentedControl* sg = (UXSegmentedControl* ?)ctl;
    if (sg != (UXSegmentedControl*)0)
        {
        sg.applyNativeSelection(value);
        }
    UXToolbar* tb = (UXToolbar* ?)ctl;
    if (tb != (UXToolbar*)0)
        {
        tb.applyNativeItemClick(value); // the value is the tapped item's tag
        }
    ctl.fire();
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        if (!gApp.isRunning())
            {
            ux_and_quit((i32)0);
            }
        }
    }
// A native EditText's text changed: the buffer is already synced shim-side;
// tell the neutral field so its onChange fires with the truth.
void uxAndFieldChanged(i32 handle, i32 node)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)256)
        {
        return;
        }
    UXTextField* f = (UXTextField* ?)(Object*)gAndCtlPeer[handle * (i32)256 + node];
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
// Return (the IME's done action) in a native EditText: the field's onSubmit.  The buffer is
// already synced (afterTextChanged runs per keystroke), so this announces and nothing else.
void uxAndFieldSubmitted(i32 handle, i32 node)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)256)
        {
        return;
        }
    UXTextField* f = (UXTextField* ?)(Object*)gAndCtlPeer[handle * (i32)256 + node];
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
void uxAndFireControl(i32 handle, i32 node)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)256)
        {
        return;
        }
    // the composed stepper folds its direction into the node's spare bits
    // (nodes stop at 63): 0x40 = increment, 0x80 = decrement
    i32 dir = (node >> (i32)6) & (i32)3;
    node = node & (i32)63;
    UXControl* ctl = (UXControl* ?)(Object*)gAndCtlPeer[handle * (i32)256 + node];
    if (ctl == (UXControl*)0)
        {
        return;
        }
    if (dir != (i32)0)
        {
        UXStepper* st = (UXStepper* ?)ctl;
        if (st != (UXStepper*)0)
            {
            if (dir == (i32)1)
                {
                st.increment();
                }
            else
                {
                st.decrement();
                }
            }
        }
    if (gAndClickEvent == (UXEvent*)0)
        {
        gAndClickEvent = new UXEvent();
        }
    gAndClickEvent.init();
    gAndClickEvent.kind = (u8)UXEventMouseDown;
    UXRect cf = ctl.absoluteFrame();
    gAndClickEvent.x = (i16)((i32)cf.x + (i32)cf.w / (i32)2);
    gAndClickEvent.y = (i16)((i32)cf.y + (i32)cf.h / (i32)2);
    gAndClickEvent.handle = handle;
    if (gEventTap != (callback void(UXEvent * e))0)
        {
        gEventTap(gAndClickEvent);
        }
    ctl.mouseDown(gAndClickEvent);
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        // stop(): a TEST quits; a real app never does
        if (!gApp.isRunning())
            {
            ux_and_quit((i32)0);
            }
        }
    }

// the drawn file panel's file operations (ux_posix_fs.h, compiled into the shim)
i32 ux_posix_listdir(u8* path, u8* out, i32 cap);
i32 ux_posix_delete(u8* path);
i32 ux_posix_rename(u8* src, u8* dst);
i32 ux_posix_copy(u8* src, u8* dst);

// A write to a save panel's staging path goes on to the document the user chose (libUXAndroid.c).
class UXAndroidFileSink : UXFileSink
    {
    bool written(u8* path)
        {
        return ux_and_file_written(path) != (i32)0;
        }
    }

class UXAndroidDriver : Object<UXViewDriver>
    {

    void init(void)
        {
        }

    // ---- boot / windows ------------------------------------------------------
    bool boot(i32* screenW, i32* screenH)
        {
        if (gAndGfx == (UXAndroidGraphics*)0)
            {
            gAndGfx = new UXAndroidGraphics();
            ux_and_set_control_fire((pointer)&uxAndFireControl);
            ux_and_set_value_changed((pointer)&uxAndValueChanged);
            ux_and_set_field_hooks((pointer)&uxAndFieldChanged);
            ux_and_set_field_submit_hooks((pointer)&uxAndFieldSubmitted);
            ux_and_set_nav_popped((pointer)&uxAndNavPopped);
            ux_and_set_touch((pointer)&uxTouch);
            ux_and_set_scroll_content((pointer)&ux_scroll_draw); // a scroll document draws its subtree
            ux_and_set_table_hooks((pointer)&xgAndTableRows, (pointer)&xgAndTableCell, (pointer)&xgAndTableCols,
                                   (pointer)&xgAndTableColTitle, (pointer)&xgAndTableColWidth,
                                   (pointer)&xgAndTableMulti, (pointer)&xgAndTableSelectSet);
            ux_and_set_outline_hooks((pointer)&xgAndTableLevel, (pointer)&xgAndTableDisclosure, (pointer)&xgAndTableToggle);
            ux_and_set_menu_pick((pointer)&xgAndMenuPick);
            }
        return ux_and_boot(screenW, screenH) != (i32)0;
        }
    // phone or tablet, by size
    // ---- GL ------------------------------------------------------------------
    // GLES 3, rendered OFFSCREEN (libUXAndroid.c): a framebuffer object at the view's pixel
    // size is the renderer's default framebuffer, presentGL reads the frame back into a Bitmap,
    // and the draw walk paints it where the view sits -- the one-surface model AppKit and Win32
    // use, so a 2-D view after the GL view in the tree is drawn over it.  Where EGL will not give
    // an ES3 context, makeGLContext returns 0 and the view is drawn by drawRect.
    i32 glKind(void)
        {
        return (i32)UX_GL_GLES3;
        }
    // No GL plane: the frame is painted in the window's own 2-D pass, ordered by tree order.
    bool compositesWithGL(void)
        {
        return false;
        }
    pointer glProc(u8* name)
        {
        return ux_and_gl_proc(name);
        }
    pointer makeGLContext(pointer view)
        {
        UXView* v = (UXView* ?)(Object*)view;
        if (v == (UXView*)0)
            {
            return (pointer)0;
            }
        UXRect f = v.frame();
        return ux_and_gl_make(view, (i32)f.w, (i32)f.h);
        }
    void destroyGLContext(pointer view)
        {
        ux_and_gl_destroy(view);
        }
    void resizeGL(pointer view, i32 w, i32 h)
        {
        ux_and_gl_resize(view, w, h);
        }
    void presentGL(pointer view)
        {
        ux_and_gl_present(view);
        }
    // The present is a readback, never a swap: there is nothing to pace.
    void glSetSwapInterval(i32 interval)
        {
        }

    // The frame clock.  Android owns the loop, so the driver answers true and arms its own
    // source: a self-reposting Handler message on the UI thread (libUXAndroid ux_and_set_turn_hook).
    bool setTurnHook(turnHook_t* fn, i32 ms)
        {
        ux_and_set_turn_hook((pointer)fn, ms);
        return true;
        }
    // a GL view's drawable and its last frame: the copy each present reads back for the Bitmap
    i32 glDrawableSize(pointer view, i32* pw, i32* ph)
        {
        return ux_and_gl_drawable(view, pw, ph);
        }
    i32 glReadFrame(pointer view, u32* out, i32 pw, i32 ph)
        {
        return ux_and_gl_read(view, out, pw, ph);
        }

    i32 formFactorClass(void)
        {
        return ux_and_form_factor();
        }
    // the screen's shape (as measured at boot)
    i32 orientation(void)
        {
        return ux_and_orientation();
        }
    // the iOS inversion, Android edition
    bool driverOwnsRunLoop(void)
        {
        return true;
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
        ux_and_set_entry((pointer)&uxAndShellStart);
        ux_and_shell_run(); // posts to the UI thread, parks
        }

    i32 windowCreate(i32 x, i32 y, i32 w, i32 h)
        {
        return ux_and_window_create(x, y, w, h);
        }
    void windowSetContent(i32 handle, pointer fn, pointer ud)
        {
        ux_and_window_set_content(handle, fn, ud);
        }
    void windowOpen(i32 handle, i32 x, i32 y, i32 w, i32 h)
        {
        ux_and_window_open(handle, x, y, w, h);
        }
    void windowDestroy(i32 handle)
        {
        ux_and_window_close(handle);
        }
    // Android windows have no chrome (action bars later)
    void windowSetTitle(i32 handle, u8* s)
        {
        }
    void windowSetSubtitle(i32 handle, u8* s)
        {
        }
    void windowSetInfo(i32 handle, u8* s)
        {
        }
    // No sound here: Not wired yet (AudioTrack over JNI is the counterpart).
    bool audioPlay(i16* pcm, i32 frames, i32 rate)
        {
        return false;
        }
    // Android shows only the APK's launcher icon (android:icon): packaging, not a call.
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
        ux_and_window_front(handle);
        }
    // ScrollView milestone
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
        ux_and_content_geometry(handle, w, h);
        }
    // the window's FrameLayout and every view on it drawn into a bitmap at a pixel a dp (libUXAndroid.c)
    i32 windowSnapshot(i32 handle, i32 x, i32 y, i32 w, i32 h, u32* out)
        {
        return ux_and_window_snapshot(handle, x, y, w, h, out);
        }
    void windowInvalidate(i32 handle)
        {
        ux_and_window_invalidate(handle);
        }
    void windowInvalidateRect(i32 handle, i32 x, i32 y, i32 w, i32 h)
        {
        ux_and_window_invalidate(handle);
        }

    // ---- native panels: the system's pickers ------------------------------------
    // The system's document picker (ACTION_OPEN_DOCUMENT): local files and every document
    // provider the device has.  The picked document is copied into the app's cache, so the path
    // that comes back reads with UXFileIO like any other.
    bool hasNativeFileOpen(void)
        {
        return true;
        }
    // The top app bar (a Toolbar: title, the theme's Up arrow) and the system Back (libUXAndroid.c)
    bool hasNativeNavigation(void)
        {
        return true;
        }
    pointer navAttach(i32 win, i32 navId, i32 x, i32 y, i32 w, i32 h)
        {
        return ux_and_nav_attach(win, navId, x, y, w, h);
        }
    void navPush(pointer nav, u8* title, i32 animated)
        {
        ux_and_nav_push(nav, title, animated);
        }
    void navPop(pointer nav, i32 animated)
        {
        ux_and_nav_pop(nav, animated);
        }
    // The system's ACTION_CREATE_DOCUMENT, asking where the document goes and under what name.  The
    // path that comes back is a staging file in the cache under the name the provider settled on;
    // UXFileIO writes it as usual, and the file sink copies each write on to the document.
    bool hasNativeFileSave(void)
        {
        return true;
        }
    i32 fileSave(u8* prompt, u8* startDir, u8* defaultName, u8* out, i32 outCap)
        {
        if (gUXFileSink == (UXFileSink*)0)
            {
            gUXFileSink = new UXAndroidFileSink();
            }
        return ux_and_file_save(defaultName, out, outCap);
        }
    i32 fileOpen(u8* prompt, u8* startDir, u8* out, i32 outCap)
        {
        return ux_and_file_open(out, outCap);
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
        return ux_and_now_ms();
        }
    // The fine clock is the coarse one in microseconds: this backend's clock has no more
    // resolution than a millisecond, and inventing bits that are not there would make a
    // frame-time measurement look precise on a backend where it is not.
    i32 nowUs(void)
        {
        return ux_and_now_ms() * (i32)1000;
        }
    void nowUTC(i32* out7)
        {
        ux_and_now_utc(out7);
        }
    i32 localOffsetMinutes(void)
        {
        return ux_and_local_offset_minutes();
        }
    bool settingGet(u8* domain, u8* key, u8* out, i32 cap)
        {
        return ux_and_setting_get(domain, key, out, cap) != (i32)0;
        }
    bool settingSet(u8* domain, u8* key, u8* value)
        {
        return ux_and_setting_set(domain, key, value) != (i32)0;
        }
    bool settingRemove(u8* domain, u8* key)
        {
        return ux_and_setting_remove(domain, key) != (i32)0;
        }
    i32 textWidth(u8* s, i32 size)
        {
        return ux_and_text_width(s, size);
        }
    i32 textWidthStyled(u8* s, u8* family, i32 size, bool bold, bool italic)
        {
        return self.textWidthWeight(s, family, size,
                                    bold ? (i32)UXWEIGHT_SEMIBOLD : (i32)UXWEIGHT_NORMAL, italic);
        }
    i32 textWidthWeight(u8* s, u8* family, i32 size, i32 weight, bool italic)
        {
        return ux_and_text_width_weight(s, family, size, weight, italic ? (i32)1 : (i32)0);
        }
    i32 textAscent(u8* family, i32 size, i32 weight, bool italic)
        {
        return ux_and_text_ascent(family, size, weight, italic ? (i32)1 : (i32)0);
        }
    i32 runPopupMenu(pointer peer, i32 x, i32 y)
        {
        return (i32)-1;
        }
    // Typeface milestone
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
        ANTree* t = (ANTree*)malloc((u32)sizeof(ANTree));
        t.cap = (i32)16;
        t.count = (i32)0;
        t.win = (i32)0;
        t.nodes = (ANNode*)calloc((u32)t.cap, (u32)sizeof(ANNode));
        return (pointer)t;
        }
    void structFree(pointer h)
        {
        if (h == (pointer)0)
            {
            return;
            }
        ANTree* t = (ANTree*)h;
        if (t.nodes != (ANNode*)0)
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
        return ((ANTree*)h).count;
        }
    void structGrow(pointer h, i32 want)
        {
        ANTree* t = (ANTree*)h;
        if (want <= t.cap)
            {
            return;
            }
        i32 cap = t.cap;
        while (cap < want)
            {
            cap = cap * (i32)2;
            }
        t.nodes = (ANNode*)realloc((pointer)t.nodes, (u32)cap * (u32)sizeof(ANNode));
        t.cap = cap;
        }
    i32 structAppend(pointer h, i32 kind, i32 x, i32 y, i32 w, i32 ht)
        {
        ANTree* t = (ANTree*)h;
        self.structGrow(h, t.count + (i32)1);
        i32 i = t.count;
        ANNode* n = &t.nodes[i];
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
        ANNode* t = ((ANTree*)h).nodes;
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
        ANNode* t = ((ANTree*)h).nodes;
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
        ANNode* n = &((ANTree*)h).nodes[i];
        n.x = (i16)x;
        n.y = (i16)y;
        n.w = (i16)w;
        n.h = (i16)ht;
        ANTree* t = (ANTree*)h;
        if (t.win != (i32)0 && ux_and_has_control(t.win, i) != (i32)0)
            {
            i32 ax = (i32)0;
            i32 ay = (i32)0;
            i32 aw = (i32)0;
            i32 ah = (i32)0;
            self.structAbsFrame(h, i, &ax, &ay, &aw, &ah);
            ux_and_set_control_frame(t.win, i, ax, ay, aw, ah);
            }
        }
    void structFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
        {
        ANNode* n = &((ANTree*)h).nodes[i];
        x[0] = (i32)n.x;
        y[0] = (i32)n.y;
        w[0] = (i32)n.w;
        ht[0] = (i32)n.h;
        }
    void structSetHidden(pointer h, i32 i, i32 on)
        {
        ((ANTree*)h).nodes[i].hidden = (i16)on;
        self.pushHiddenSubtree(h, i);
        }

    // HIDDEN IS INHERITED — see UXAppKitDriver.effectiveHidden for the full
    // reasoning.  In short: a native control is its own platform view, so it
    // does not disappear because an ancestor did; the app-drawn walk skips a
    // hidden subtree while native controls stayed visible, and the two halves
    // of one tree disagreed about what "hidden" means.
    //
    // NOT YET VERIFIED on Android — no gate yet; the emulator can run one.
    // The shape is identical to the AppKit, GTK and Win32 copies, all three of
    // which ARE gated, so the risk is low; but identical-looking is not tested.
    // To close it: port test_hiddeninherit.xc, whose only platform-specific
    // parts are the driver construction and the capture call, then delete this
    // paragraph.
    // Node 0 is the root.  Walking parents must reach it; hitting -1 first
    // means this node was removed from the tree and is merely still occupying
    // its slot in the array.
    i32 isDetached(pointer h, i32 i)
        {
        ANNode* t = ((ANTree*)h).nodes;
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
        ANNode* t = ((ANTree*)h).nodes;
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
        ANTree* t = (ANTree*)h;
        if (i < (i32)0 || i >= t.count)
            {
            return;
            }
        if (t.win != (i32)0 && ux_and_has_control(t.win, i) != (i32)0)
            {
            ux_and_set_control_hidden(t.win, i, self.effectiveHidden(h, i));
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
        return (i32)((ANTree*)h).nodes[i].hidden;
        }
    void structSetEnabled(pointer h, i32 i, i32 on)
        {
        ((ANTree*)h).nodes[i].enabled = (i16)on;
        ANTree* t = (ANTree*)h;
        if (t.win != (i32)0 && ux_and_has_control(t.win, i) != (i32)0)
            {
            ux_and_set_control_enabled(t.win, i, on);
            }
        }
    i32 structIsEnabled(pointer h, i32 i)
        {
        return (i32)((ANTree*)h).nodes[i].enabled;
        }
    void structSetSelected(pointer h, i32 i, i32 on)
        {
        ((ANTree*)h).nodes[i].selected = (i16)on;
        }
    i32 structIsSelected(pointer h, i32 i)
        {
        return (i32)((ANTree*)h).nodes[i].selected;
        }
    void structSetClips(pointer h, i32 i, i32 on)
        {
        ((ANTree*)h).nodes[i].clips = (i16)on;
        }
    void structSetClipShape(pointer h, i32 i, i32 radius, i32 inset)
        {
        ((ANTree*)h).nodes[i].clipR = (i16)radius;
        ((ANTree*)h).nodes[i].clipIn = (i16)inset;
        }
    void structSetSpec(pointer h, i32 i, pointer spec)
        {
        ((ANTree*)h).nodes[i].spec = spec;
        }
    void structSetPeer(pointer h, i32 i, pointer peer)
        {
        ((ANTree*)h).nodes[i].peer = peer;
        }
    void structSetAutoresize(pointer h, i32 i, i32 mask)
        {
        }
    bool driverAutoresizes(void)
        {
        return false;
        }
    void structSetSelectable(pointer h, i32 i, i32 on)
        {
        ((ANTree*)h).nodes[i].selectable = (i16)on;
        }
    void structSetEditable(pointer h, i32 i, i32 on)
        {
        ((ANTree*)h).nodes[i].editable = (i16)on;
        }

    void treeOffset(pointer tree, i32 obj, i32* ax, i32* ay)
        {
        ax[0] = (i32)0;
        ay[0] = (i32)0;
        }
    void structAbsFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
        {
        ANNode* t = ((ANTree*)h).nodes;
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
    i32 hitOne(ANNode* t, i32 i, i32 ox, i32 oy, i32 px, i32 py)
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
        return self.hitOne(((ANTree*)tree).nodes, start, (i32)0, (i32)0, x, y);
        }

    // ---- native realization --------------------------------------------------
    // Real android.widget controls overlay the shadow tree: a Button per
    // UXKindButton, a TextView per Label — created once, repositioned
    // thereafter, peers parked for the fire path.  Everything else stays
    // app-drawn through drawRect this slice; the overlay set grows exactly
    // as iOS's did.
    // UXKindShield is a bare view above every control (ux_and_make_shield), so Android delivers a
    // touch on a design surface to it, and so to the toolkit, instead of to the control under it.
    // It is raised again at the end of each realize, and never moves into a scroll document.
    i32 isUnderTable(ANTree* t, i32 i)
        {
        i16 p = t.nodes[i].parent;
        while (p >= (i16)0)
            {
            if ((i32)t.nodes[p].kind == (i32)UXKindTable)
                {
                UXTableView* tv = (UXTableView* ?)(Object*)t.nodes[p].peer;
                if (tv != (UXTableView*)0)
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
        ANTree* t = (ANTree*)tree;
        t.win = handle;
        for (i32 i = (i32)0; i < t.count; i = i + (i32)1)
            {
            ANNode* n = &t.nodes[i];
            i32 ax = (i32)0;
            i32 ay = (i32)0;
            i32 aw = (i32)0;
            i32 ah = (i32)0;
            self.structAbsFrame(tree, i, &ax, &ay, &aw, &ah);
            // A native table covers its whole subtree (rows, cells, its scroller).
            if (self.isUnderTable(t, i) != (i32)0)
                {
                continue;
                }
            if (n.kind == (i32)UXKindShield)
                {
                ux_and_make_shield(handle, i, ax, ay, aw, ah, self.effectiveHidden(tree, i));
                continue;
                }
            if (n.kind == (i32)UXKindScroll)
                {
                // A ScrollView over the scroll view; its document draws the scroll view's document
                // subtree (ux_scroll_draw), at the document's own place in the window.
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
                if (ux_and_has_control(handle, i) == (i32)0)
                    {
                    ux_and_make_scroll(handle, i, ax, ay, aw, ah, sv.nativeContentHeight(), n.peer, dx, dy);
                    }
                else
                    {
                    ux_and_set_control_frame(handle, i, ax, ay, aw, ah);
                    ux_and_scroll_reload(handle, i, aw, ah, sv.nativeContentHeight(), dx, dy);
                    }
                ux_and_scroll_style(handle, i, sv.nativeCornerRadius(), sv.nativeBorderRGB());
                ux_and_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                continue;
                }
            if (n.kind == (i32)UXKindTable)
                {
                UXTableView* tv = (UXTableView* ?)(Object*)n.peer;
                if (tv == (UXTableView*)0 || i >= (i32)64)
                    {
                    continue;
                    }
                if (ux_and_has_control(handle, i) == (i32)0)
                    {
                    // an outline is the same list, its flattened rows indented with arrows
                    ux_and_make_table(handle, i, ax, ay, aw, ah, n.peer, tv.nativeIsOutline());
                    }
                else
                    {
                    ux_and_set_control_frame(handle, i, ax, ay, aw, ah);
                    ux_and_table_reload(handle, i);
                    }
                if (tv.nativeSelectionNeedsPush())
                    {
                    i32 rows[256];
                    i32 nsel = tv.selectedRowList(&rows[(i32)0], (i32)256);
                    ux_and_table_select(handle, i, &rows[(i32)0], nsel);
                    tv.clearNativeSelectionPush();
                    }
                ux_and_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                continue;
                }
            if (ux_and_has_control(handle, i) != (i32)0)
                {
                ux_and_set_control_frame(handle, i, ax, ay, aw, ah);
                ux_and_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                ux_and_set_control_enabled(handle, i, (i32)n.enabled);
                // the model is the truth for toggles: push it back into the
                // native on every display (the Win32 BM_SETCHECK discipline)
                if (n.kind == (i32)UXKindCheckbox)
                    {
                    UXCheckbox* cbp = (UXCheckbox* ?)(Object*)n.peer;
                    if (cbp != (UXCheckbox*)0)
                        {
                        ux_and_set_checkbox(handle, i, cbp.isChecked() ? (i32)1 : (i32)0);
                        }
                    }
                else if (n.kind == (i32)UXKindRadio)
                    {
                    UXRadioButton* rbp = (UXRadioButton* ?)(Object*)n.peer;
                    if (rbp != (UXRadioButton*)0)
                        {
                        ux_and_set_checkbox(handle, i, rbp.isSelected() ? (i32)1 : (i32)0);
                        }
                    }
                else if (n.kind == (i32)UXKindSegmented)
                    {
                    UXSegmentedControl* sgp = (UXSegmentedControl* ?)(Object*)n.peer;
                    if (sgp != (UXSegmentedControl*)0)
                        {
                        for (i32 j = (i32)0; j < sgp.nativeSegCount(); j = j + (i32)1)
                            {
                            ux_and_seg_set(handle, i, j, sgp.nativeSegSelected(j));
                            }
                        }
                    }
                // and the values: an app's setValue, advancing progress or a new selection shows
                else if (n.kind == (i32)UXKindSlider)
                    {
                    UXSlider* slp = (UXSlider* ?)(Object*)n.peer;
                    if (slp != (UXSlider*)0)
                        {
                        ux_and_set_slider_value(handle, i, slp.nativeValue());
                        }
                    }
                else if (n.kind == (i32)UXKindProgress)
                    {
                    UXProgressBar* pgp = (UXProgressBar* ?)(Object*)n.peer;
                    if (pgp != (UXProgressBar*)0)
                        {
                        ux_and_set_progress(handle, i, pgp.nativeFractionMille(), pgp.nativeIndeterminate());
                        }
                    }
                else if (n.kind == (i32)UXKindPopup)
                    {
                    UXPopUpButton* pup = (UXPopUpButton* ?)(Object*)n.peer;
                    // only when it moved: a Spinner reports even a programmatic selection back
                    if (pup != (UXPopUpButton*)0 && gAndPopupShown[handle * (i32)256 + i] != pup.nativeSelected() + (i32)1)
                        {
                        ux_and_popup_select(handle, i, pup.nativeSelected());
                        gAndPopupShown[handle * (i32)256 + i] = pup.nativeSelected() + (i32)1;
                        }
                    }
                continue;
                }
            if (n.kind == (i32)UXKindButton)
                {
                u8* title = n.spec != (pointer)0 ? (u8*)n.spec : (u8*)"";
                ux_and_make_button(handle, i, ax, ay, aw, ah, title);
                gAndCtlPeer[handle * (i32)256 + i] = n.peer;
                }
            else if (n.kind == (i32)UXKindLabel && n.spec != (pointer)0)
                {
                ux_and_make_label(handle, i, ax, ay, aw, ah, (u8*)n.spec);
                }
            else if (n.kind == (i32)UXKindCheckbox)
                {
                UXCheckbox* cb = (UXCheckbox* ?)(Object*)n.peer;
                if (cb != (UXCheckbox*)0)
                    {
                    u8* title = n.spec != (pointer)0 ? (u8*)n.spec : (u8*)"";
                    ux_and_make_checkbox(handle, i, ax, ay, aw, ah, title,
                                         cb.isChecked() ? (i32)1 : (i32)0);
                    gAndCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindSlider)
                {
                UXSlider* sv = (UXSlider* ?)(Object*)n.peer;
                if (sv != (UXSlider*)0)
                    {
                    ux_and_make_slider(handle, i, ax, ay, aw, ah,
                                       sv.nativeMin(), sv.nativeMax(), sv.nativeValue());
                    gAndCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindProgress)
                {
                UXProgressBar* pgv = (UXProgressBar* ?)(Object*)n.peer;
                if (pgv != (UXProgressBar*)0)
                    {
                    ux_and_make_progress(handle, i, ax, ay, aw, ah, pgv.nativeFractionMille());
                    gAndCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindPopup)
                {
                UXPopUpButton* pv = (UXPopUpButton* ?)(Object*)n.peer;
                if (pv != (UXPopUpButton*)0)
                    {
                    ux_and_make_popup(handle, i, ax, ay, aw, ah);
                    for (i32 j = (i32)0; j < pv.nativeItemCount(); j = j + (i32)1)
                        {
                        ux_and_popup_add_item(handle, i, pv.nativeItemTitle(j));
                        }
                    ux_and_popup_select(handle, i, pv.nativeSelected());
                    gAndPopupShown[handle * (i32)256 + i] = pv.nativeSelected() + (i32)1;
                    gAndCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindRadio)
                {
                UXRadioButton* rv = (UXRadioButton* ?)(Object*)n.peer;
                if (rv != (UXRadioButton*)0)
                    {
                    u8* title = n.spec != (pointer)0 ? (u8*)n.spec : (u8*)"";
                    ux_and_make_radio(handle, i, ax, ay, aw, ah, title,
                                      rv.isSelected() ? (i32)1 : (i32)0);
                    gAndCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindToolbar)
                {
                UXToolbar* tv = (UXToolbar* ?)(Object*)n.peer;
                if (tv != (UXToolbar*)0)
                    {
                    ux_and_make_toolbar(handle, i, ax, ay, aw, ah);
                    for (i32 j = (i32)0; j < tv.nativeItemCount(); j = j + (i32)1)
                        {
                        ux_and_toolbar_add(handle, i, tv.nativeItemType(j), tv.nativeItemLabel(j), tv.nativeItemTag(j));
                        }
                    gAndCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindSegmented)
                {
                UXSegmentedControl* gv = (UXSegmentedControl* ?)(Object*)n.peer;
                if (gv != (UXSegmentedControl*)0)
                    {
                    ux_and_make_segmented(handle, i, ax, ay, aw, ah, gv.nativeSegCount(), gv.nativeMultiSelect());
                    for (i32 j = (i32)0; j < gv.nativeSegCount(); j = j + (i32)1)
                        {
                        ux_and_seg_set_label(handle, i, j, gv.nativeSegLabel(j));
                        ux_and_seg_set(handle, i, j, gv.nativeSegSelected(j));
                        }
                    gAndCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindStepper)
                {
                UXStepper* sv = (UXStepper* ?)(Object*)n.peer;
                if (sv != (UXStepper*)0)
                    {
                    ux_and_make_stepper(handle, i, ax, ay, aw, ah);
                    gAndCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            else if (n.kind == (i32)UXKindField)
                {
                ANField* f = (ANField*)n.spec;
                if (f != (ANField*)0)
                    {
                    ux_and_make_field(handle, i, ax, ay, aw, ah, f.buf, f.cap, f.secure);
                    gAndCtlPeer[handle * (i32)256 + i] = n.peer;
                    }
                }
            // apply the node's INITIAL state to a control created THIS pass —
            // the has-control branch above only serves later displays, so a
            // widget disabled/hidden before its first realize stayed pristine
            // (the state-pair portraits caught identical enabled/disabled
            // buttons on every single-pass backend)
            if (ux_and_has_control(handle, i) != (i32)0)
                {
                if (n.enabled == (i16)0)
                    {
                    ux_and_set_control_enabled(handle, i, (i32)0);
                    }
                if (self.effectiveHidden(tree, i) != (i32)0)
                    {
                    ux_and_set_control_hidden(handle, i, (i32)1);
                    }
                }
            }
        // A native control inside a scroll view goes into that container's document, so it scrolls
        // and clips with it.  A scroll, a table or a GL view owns its own surface and stays put.
        for (i32 i = (i32)0; i < t.count; i = i + (i32)1)
            {
            i32 kk = (i32)t.nodes[i].kind;
            if (kk == (i32)UXKindScroll || kk == (i32)UXKindTable || kk == (i32)UXKindGLView || kk == (i32)UXKindShield || ux_and_has_control(handle, i) == (i32)0)
                {
                continue;
                }
            i32 anc = (i32)t.nodes[i].parent;
            while (anc >= (i32)0)
                {
                if ((i32)t.nodes[anc].kind == (i32)UXKindScroll && ux_and_has_control(handle, anc) != (i32)0)
                    {
                    i32 cx = (i32)0;
                    i32 cy = (i32)0;
                    i32 cw = (i32)0;
                    i32 chh = (i32)0;
                    self.structAbsFrame(tree, i, &cx, &cy, &cw, &chh);
                    ux_and_reparent_to_scroll(handle, i, anc, cx, cy, cw, chh);
                    break;
                    }
                anc = (i32)t.nodes[anc].parent;
                }
            }
        ux_and_raise_shield(handle); // above anything this pass created
        }

    // ---- painting ------------------------------------------------------------
    void treeSetUserDraw(pointer fn, pointer ud)
        {
        gAndUserFn = fn;
        gAndUserUd = ud;
        }
    void drawOne(ANTree* t, i32 i)
        {
        if (i < (i32)0 || t.nodes[i].hidden != (i16)0)
            {
            return;
            }
        // A node with a native control paints itself — never draw under it.
        bool native = t.win != (i32)0 && ux_and_has_control(t.win, i) != (i32)0;
        // ...and a native table paints its whole subtree: its rows are the ListView's.
        if (native && (t.nodes[i].kind == (i32)UXKindTable || t.nodes[i].kind == (i32)UXKindScroll))
            {
            return; // ...as a native scroll container's document paints its own (ux_scroll_draw)
            }
        if (!native)
            {
            // The GEM rule: every non-native node is app-drawn through the
            // userdraw seam — View AND the custom-drawn controls.
            if (gAndUserFn != (pointer)0)
                {
                // A view's drawing stays INSIDE ITS FRAME, as an NSView's does.
                i32 vx = (i32)0;
                i32 vy = (i32)0;
                i32 vw = (i32)0;
                i32 vh = (i32)0;
                self.structAbsFrame((pointer)t, i, &vx, &vy, &vw, &vh);
                ux_and_clip(vx - gAndDrawOX, vy - gAndDrawOY, vw, vh); // in the surface's own space
                // A GL view that owns a context is painted with its last frame, never by
                // drawRect: the two are alternative renderers.
                bool gl = t.nodes[i].kind == (i32)UXKindGLView && t.nodes[i].peer != (pointer)0
                          && ux_and_gl_paint(t.nodes[i].peer, t.win, vx, vy, vw, vh) != (i32)0;
                if (!gl)
                    {
                    UXAndUserDrawFn* f = (UXAndUserDrawFn*)gAndUserFn;
                    f((pointer)t.nodes, i, gAndUserUd);
                    }
                ux_and_clip_end();
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
            ux_and_clip_round(cx + ci - gAndDrawOX, cy + ci - gAndDrawOY, cw - ci * (i32)2, chh - ci * (i32)2, (i32)t.nodes[i].clipR);
            }
        i16 c = t.nodes[i].head;
        while (c >= (i16)0)
            {
            self.drawOne(t, (i32)c);
            c = t.nodes[c].next;
            }
        if (clips)
            {
            ux_and_clip_end();
            }
        }
    void treeDraw(pointer tree, i32 start, i32 clx, i32 cly, i32 clw, i32 clh)
        {
        gAndDrawTree = (ANTree*)tree;
        self.drawOne((ANTree*)tree, start);
        }
    // the view is clipped to its frame by this driver's own tree walk
    void endViewDraw(void)
        {
        }
    UXGraphics* beginViewDraw(i32 ax, i32 ay, i32 aw, i32 ah)
        {
        gAndGfx.bind(UXGeom.make((i16)(ax - gAndDrawOX), (i16)(ay - gAndDrawOY), (i16)aw, (i16)ah));
        return gAndGfx;
        }
    void setDrawOffset(i32 x, i32 y)
        {
        gAndDrawOX = x;
        gAndDrawOY = y;
        }
    // A scroll view is a ScrollView, which owns the offset (realizeTree)
    bool scrollsNatively(void)
        {
        return true;
        }
    void nativeScrollTo(pointer h, i32 node, i32 px)
        {
        ux_and_scroll_set(((ANTree*)h).win, node, px);
        }
    i32 nativeScrollPx(pointer h, i32 node)
        {
        return ux_and_scroll_get(((ANTree*)h).win, node);
        }

    // ---- text editing (the shared engine; the EditText overlay is a milestone) ----
    pointer fieldEditorNew(u8* buf, i32 cap)
        {
        ANField* f = (ANField*)malloc((u32)sizeof(ANField));
        f.buf = buf;
        f.cap = cap;
        f.valid = (u8*)0;
        f.place = (u8*)0;
        f.secure = (i32)0;
        return (pointer)f;
        }
    void fieldEditorSetValid(pointer ed, u8* valid)
        {
        ((ANField*)ed).valid = valid;
        }
    void fieldEditorSetPlaceholder(pointer ed, u8* s)
        {
        ((ANField*)ed).place = s;
        }
    void fieldEditorSetSecure(pointer ed, i32 on)
        {
        ((ANField*)ed).secure = on;
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
        ANField* f = (ANField*)((ANTree*)tree).nodes[obj].spec;
        if (f == (ANField*)0)
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

    // ---- menus / alerts: their milestones (options menu, AlertDialog) --------
    // No menu bar on a phone: the app's menus hang from the overflow button (UXMenuButton in the
    // bridge), handed over as one string.  An item's ordinal is its index in its title.
    pointer menuBuild(pointer defs, i32 n, i32 screenW)
        {
        return (pointer)UXMenuEncode.encode(defs, n);
        }
    void menuShow(pointer menu, i32 show)
        {
        ux_and_menu_set(show != (i32)0 && menu != (pointer)0 ? (u8*)menu : (u8*)"");
        }
    i32 menuItemOrd(pointer menu, i32 titleOrd, i32 itemObj)
        {
        return itemObj;
        }
    void menuCheck(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
        {
        ux_and_menu_state(titleOrd, itemOrd, (i32)0, on);
        }
    void menuEnable(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
        {
        ux_and_menu_state(titleOrd, itemOrd, (i32)1, on);
        }
    // Modal for real: AlertDialog behind a nested Looper.loop() in the shim —
    // a listener records the pick and unwinds the nested loop with a marker
    // exception (the classic Android sync-dialog shape).  Negative = cancel.
    i32 alertRun(i32 icon, u8* lines, u8* buttons, i32 defaultBtn)
        {
        return ux_and_alert(icon, lines, buttons, defaultBtn);
        }

    // ---- events: the B + A model — input arrives via listeners, never here.
    void nextEvent(i32 timeoutMs, UXEvent* ev)
        {
        ev.init();
        }
    void pumpMessages(i32 timeoutMs, UXEvent* ev)
        {
        ev.init();
        }
    i32 windowAtPoint(i32 x, i32 y)
        {
        return (i32)0;
        }
    // native controls own drag
    // the platform owns the loop: a drag arrives as touch events (UXTouch.xc)
    bool dragTrackingIsModal(void)
        {
        return false;
        }
    i32 trackDragStep(i32* x, i32* y)
        {
        return (i32)0;
        }

    i32 liveNativeCount(void)
        {
        return ux_and_native_count();
        }
    }
