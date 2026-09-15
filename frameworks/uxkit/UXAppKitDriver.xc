// UXAppKitDriver.xc — the AppKit realization of UXViewDriver.  The sibling of UXWin32Driver: it
// implements the SAME neutral interface, so the neutral toolkit (UXView/UXWindow/UXViewTree/the
// widgets) runs native on macOS unchanged.
//
// Like the Win32 driver it keeps its own SHADOW TREE (a flat node array with parent/sibling links)
// and walks it for painting and hit-testing — that logic is backend-neutral and shared in shape
// with UXWin32Driver.  What is AppKit-specific goes through libUXAppKit.m (the shim owns every
// NSRect): NSApplication/NSWindow, a flipped UXDrawView whose drawRect: is the paint seam, and an
// NSGraphicsContext drawing vocabulary (UXCocoaGraphics).
//
// Events, menus, alerts, scrolling, tables/outlines and the native open/colour/font panels are all
// live here now.  What is not: windowSetSubtitle/Info/Icon/Modified (NSWindow has subtitle and
// documentEdited — this is unfinished, not unavailable), and the toolkit's own file-panel ops
// (listDir/fileDelete/...), which are deliberately unused because macOS presents NSOpenPanel.
#import "UXViewDriver.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXCocoaGraphics.xc"
#import "UXEvent.xc"
#import "UXApplication.xc"      // interactive mode drives the toolkit's dispatch under [NSApp run]
#import "UXTableView.xc"        // a native NSTableView overlay reads its data straight from this
#import "UXOutlineView.xc"      // a native NSOutlineView overlay reads the item tree from this
#import "UXControl.xc"          // UXCheckbox / UXRadioButton — read toggle state for native check/radio
#import "UXSlider.xc"           // a native NSSlider overlay reads/writes this widget's value
#import "UXPopUpButton.xc"      // a native NSPopUpButton overlay reads its items + selection
#import "UXStepper.xc"          // a native NSStepper overlay
#import "UXSegmentedControl.xc" // a native NSSegmentedControl overlay
#import "UXProgressBar.xc"      // a native NSProgressIndicator overlay
#import "UXToolbar.xc"          // realized as a native NSToolbar (window chrome), not a subview
#import "UXLibc.xc"

// The shim (libUXAppKit.m).  Primitive signatures only — no NSRect crosses into xtc.
void ux_ak_boot(void);
i32 ux_ak_window_create(i32 x, i32 y, i32 w, i32 h);
void ux_ak_window_set_content(i32 handle, pointer fn, pointer ud);
void ux_ak_window_open(i32 handle);
void ux_ak_window_front(i32 handle);
i32 ux_ak_open_panel(u8* prompt, u8* startDir, u8* out, i32 outCap);
i32 ux_ak_color_panel(i32 r, i32 g, i32 b, i32* outR, i32* outG, i32* outB);
i32 ux_ak_font_panel(u8* inFamily, i32 inSize, i32 inBold, i32 inItalic, u8* outFamily, i32 outCap, i32* outSize, i32* outBold, i32* outItalic);
void ux_ak_window_close(i32 handle);
void ux_ak_window_set_title(i32 handle, u8* s);
void ux_ak_window_set_subtitle(i32 handle, u8* s);  // NSWindow.subtitle (macOS 11+)
void ux_ak_window_set_modified(i32 handle, i32 on); // the dot in the close button
i32 ux_ak_window_modified(i32 handle);              // read-back, for tests
i32 ux_ak_window_subtitle(i32 handle, u8* out, i32 cap);
void ux_ak_window_invalidate(i32 handle);
i32 ux_ak_native_count(void);
void ux_ak_content_size(i32 handle, i32 w, i32 h); // scrolling: document-view extent + set offset
void ux_ak_set_scroll(i32 handle, i32 x, i32 y);
void ux_ak_table_select(i32 handle, i32 node, i32* rows, i32 n); // model selection -> NSTableView
void ux_ak_content_geometry(i32 handle, i32* w, i32* h);         // the window's current content-area size
i32 ux_ak_next_event(i32 timeoutMs, i32* kind, i32* x, i32* y, i32* key);
void ux_ak_post_click(i32 handle, i32 tx, i32 ty); // tests: simulate the OS delivering a click
void ux_ak_post_key(i32 ch);                       // tests: simulate a keystroke
void ux_ak_post_resize(i32 handle, i32 w, i32 h);  // tests: simulate the user resizing a window
void ux_ak_post_quit(void);                        // tests: end the run loop
void ux_ak_set_interactive(i32 on);                // GUI mode: show windows, block on real events
i32 ux_ak_interactive(void);
i32 ux_ak_capture(void); // capture booth: native controls realized, no window shown
void ux_ak_set_capture(i32 on);
void ux_ak_run(void); // interactive: [NSApp run] owns the loop
i32 ux_ak_quit(void); // nonzero once the close box was hit
void ux_ak_stop(void);
void ux_ak_set_dispatch(pointer fn);     // register the toolkit event forwarder
void ux_ak_set_control_fire(pointer fn); // register the control-click -> action forwarder
pointer ux_ak_menu_new(void);
pointer ux_ak_menu_add_title(pointer bar, u8* title);
void ux_ak_menu_add_item(pointer sub, u8* text, i32 tag, i32 checked, i32 disabled, i32 sep);
void ux_ak_menu_set_main(pointer bar);
void ux_ak_menu_check(pointer bar, i32 tag, i32 on);
void ux_ak_menu_enable(pointer bar, i32 tag, i32 on);
i32 ux_ak_alert(i32 icon, u8* lines, u8* buttons, i32 defaultBtn);
// Native controls (interactive): real NSButton/NSTextField subviews overlaying the shadow tree.
i32 ux_ak_has_control(i32 handle, i32 node);
void ux_ak_make_button(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* title);
void ux_ak_make_check(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* title, i32 flags); // flags: bit0=checked, bit1=radio (8 args: bug 017)
void ux_ak_set_control_check(i32 handle, i32 node, i32 on);
void ux_ak_set_control_align(i32 handle, i32 node, i32 a); // label/field text alignment
i32 ux_ak_control_align(i32 handle, i32 node);             // ...and what it actually is
void ux_ak_make_field(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* buf, i32 cap, i32 secure);
void ux_ak_update_field(i32 handle, i32 node);
void ux_ak_make_label(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, u8* text);
void ux_ak_set_label_text(i32 handle, i32 node, u8* text);
void ux_ak_set_control_frame(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h);
void ux_ak_set_control_enabled(i32 handle, i32 node, i32 on);
i32 ux_ak_control_enabled(i32 handle, i32 node);
i32 ux_ak_control_check(i32 handle, i32 node); // the toggle's ACTUAL state; -1 = no control
i32 ux_ak_control_frame(i32 handle, i32 node, i32* x, i32* y, i32* w, i32* h);
void ux_ak_set_control_hidden(i32 handle, i32 node, i32 on);
void ux_ak_set_control_autoresize(i32 handle, i32 node, i32 mask); // springs & struts (live resize)
// Native NSTableView (interactive): make one bound to the peer UXTableView, and reload its data.
// The shim pulls rows/columns/selection through the hooks registered by ux_ak_set_table_hooks.
void ux_ak_make_table(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, pointer peer);
void ux_ak_table_reload(i32 handle, i32 node);
void ux_ak_set_table_hooks(pointer rows, pointer cell, pointer cols, pointer title, pointer width,
                           pointer multi, pointer selectset);
// Native NSOutlineView (interactive): a TREE bound to the peer UXOutlineView, driven by item hooks.
void ux_ak_make_outline(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, pointer peer);
void ux_ak_outline_reload(i32 handle, i32 node);
void ux_ak_set_outline_hooks(pointer children, pointer child, pointer expandable, pointer value, pointer didexpand);
// The NSTextField's controlTextDidChange: calls this (handle, node) after syncing the buffer.
void ux_ak_set_field_hooks(pointer changed);
void ux_ak_set_field_placeholder(i32 handle, i32 node, u8* text); // -> NSTextField placeholderString
// Native NSScrollView over a generic scroll view: its document view draws the scroll's subtree.
void ux_ak_make_scroll(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 contentH, pointer sv);
void ux_ak_scroll_reload(i32 handle, i32 node, i32 contentH);
void ux_ak_scroll_set(i32 handle, i32 node, i32 px); // drive it from the toolkit
i32 ux_ak_scroll_get(i32 handle, i32 node);          // ...and read where it ended up
void ux_ak_set_scroll_content(pointer fn);
i32 ux_ak_drag_next(i32* x, i32* y);
// The input shield (UXKindShield): a real NSView above the controls, so a click on a
// design surface reaches the toolkit instead of pressing the button under it.
void ux_ak_make_shield(i32 handle, i32 x, i32 y, i32 w, i32 h, i32 hidden);
void ux_ak_raise_shield(i32 handle);
i32 ux_ak_has_shield(i32 handle); // one modal drag-track step (split divider): 1 = dragging, 0 = up
// Native value controls (slider/stepper/popup/segmented): a value-changed callback carries the number.
void ux_ak_set_value_changed(pointer fn);
void ux_ak_make_slider(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 lo, i32 hi, i32 val);
void ux_ak_set_slider_value(i32 handle, i32 node, i32 val);
void ux_ak_make_popup(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h);
void ux_ak_popup_add_item(i32 handle, i32 node, u8* title);
void ux_ak_popup_select(i32 handle, i32 node, i32 i);
void ux_ak_make_stepper(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 lo, i32 hi, i32 step, i32 wraps, i32 val);
void ux_ak_set_stepper_value(i32 handle, i32 node, i32 val);
void ux_ak_make_segmented(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h, i32 nseg);
void ux_ak_seg_set_label(i32 handle, i32 node, i32 seg, u8* label);
void ux_ak_seg_select(i32 handle, i32 node, i32 seg);
void ux_ak_make_progress(i32 handle, i32 node, i32 x, i32 y, i32 w, i32 h);
void ux_ak_set_progress(i32 handle, i32 node, i32 mille, i32 indeterminate);
void ux_ak_toolbar_begin(i32 handle, i32 node); // build a native NSToolbar (window chrome)
void ux_ak_toolbar_add(i32 handle, i32 node, i32 tag, u8* label, i32 type);
void ux_ak_toolbar_install(i32 handle, i32 node);

// The draw-seam callbacks, as callable function-pointer types (xtc can call these directly).
typedef void UXContentFn(i32 handle, i32 wx, i32 wy, i32 ww, i32 wh, pointer ud);
typedef i32 UXUserDrawFn(pointer tree, i32 obj, pointer ud);

// ── the shadow tree (shape shared with UXWin32Driver) ───────────────────────
struct AKNode
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
    i32 autoresize;
    pointer spec;
    pointer peer; // the neutral widget (UXTableView / UXCheckbox / …), kept out of spec so a
                  // control's title (also in spec) survives — see structSetPeer
    i16 next;
    i16 head;
    i16 tail;
    i16 parent;
    }
    // `win` is the window handle this tree was last realized into.  The native controls live in
    // g_ctl[handle][node] on the shim side, so any driver op that reaches a control needs the handle —
    // and the neutral tree ops only ever hand over the tree.  realizeTree records it here.
    struct AKTree
    {
    AKNode* nodes;
    i32 count;
    i32 cap;
    i32 win;
    }

    // A field editor: the app's buffer, capacity, optional per-position validation string.  AppKit has
    // no edit engine for a custom-drawn field, so the driver edits it — same code as the Win32 driver.
    struct AKField
    {
    u8* buf;
    i32 cap;
    u8* valid;
    u8* place;
    i32 secure;
    }

    // ── driver state ────────────────────────────────────────────────────────────
    UXCocoaGraphics* gAKGfx; // the one graphics object, bound per paint
i32 gAKDrawOX;               // draw-origin offset (a scroll view's document surface subtracts its
i32 gAKDrawOY;               // own absolute position, so its subtree draws at that surface's 0,0)
pointer gAKUserFn;           // the per-view draw callback (ux_userdraw)
pointer gAKUserUd;

// Interactive mode: [NSApp run] owns the loop, so content events arrive here (from the content
// view's mouseDown:/keyDown: and menu items) rather than through the neutral run loop's nextEvent.
// This trampoline is registered with the shim (ux_ak_set_dispatch) and dispatches straight into the
// running app.  A close/stop breaks [NSApp run] so the neutral loop can unwind.
UXApplication* gAKApp;
UXEvent* gAKEvent;
i32 gAKMouseWin; // handle of the window that received the current mouse-down (ak_mouseDown)
void xgAKDispatch(i32 kind, i32 x, i32 y, i32 key)
    {
    if (gAKApp == (UXApplication*)0)
        {
        return;
        }
    if (gAKEvent == (UXEvent*)0)
        {
        gAKEvent = new UXEvent();
        }
    gAKEvent.init();
    gAKEvent.kind = (u8)kind;
    gAKEvent.x = (i16)x;
    gAKEvent.y = (i16)y;
    gAKEvent.key = (u16)key;
    // title+2 ordinal
    if (kind == (i32)UXEventMenuSelect)
        {
        gAKEvent.a = x + (i32)2;
        gAKEvent.b = y;
        }
    // x carried the handle
    if (kind == (i32)UXEventResize)
        {
        gAKEvent.handle = x;
        }
    // key carried the window handle
    if (kind == (i32)UXEventMouseDown)
        {
        gAKMouseWin = key;
        }
    gAKApp.dispatchEvent(gAKEvent);
    gAKApp.displayIfNeeded();
    // close box -> quit
    if (kind == (i32)UXEventClose)
        {
        gAKApp.stop();
        }
    // stop() called -> break [NSApp run]
    if (!gAKApp.isRunning())
        {
        ux_ak_stop();
        }
    }

// A native button/check/radio was clicked: fire its neutral widget's action DIRECTLY (by handle+node),
// no synthetic-click hit-test.  The widget rides gAKCtlPeer, populated in realizeTree.
pointer gAKCtlPeer[16384]; // [handle*256 + node] -> the control's neutral widget
UXEvent* gAKClickEvent;
void xgAKFireControl(i32 handle, i32 node)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)256)
        {
        return;
        }
    UXControl* ctl = (UXControl* ?)gAKCtlPeer[handle * (i32)256 + node];
    if (ctl == (UXControl*)0)
        {
        return;
        }
    if (gAKClickEvent == (UXEvent*)0)
        {
        gAKClickEvent = new UXEvent();
        }
    gAKClickEvent.init();
    gAKClickEvent.kind = (u8)UXEventMouseDown;
    // Position it and announce it to the tap before acting.  AppKit hands us a notification, not a
    // click, and fires the action by handle+node with no hit-test at all — so a tap watching the
    // app's dispatch recorded NOTHING here.  A positioned event is also what makes it replayable:
    // replay goes back through the ordinary hit test to this same control.
    UXRect cf = ctl.absoluteFrame();
    gAKClickEvent.x = (i16)((i32)cf.x + (i32)cf.w / (i32)2);
    gAKClickEvent.y = (i16)((i32)cf.y + (i32)cf.h / (i32)2);
    gAKClickEvent.handle = handle;
    if (gEventTap != (callback void(UXEvent * e))0)
        {
        gEventTap(gAKClickEvent);
        }
    ctl.mouseDown(gAKClickEvent); // toggles checkbox/radio, fires the action
    if (gAKApp != (UXApplication*)0)
        {
        gAKApp.displayIfNeeded(); // reflect effects (field clear, status, check)
        // Quit -> break [NSApp run]
        if (!gAKApp.isRunning())
            {
            ux_ak_stop();
            }
        }
    }

// A native value control (slider/…) moved: adopt the number into the peer widget, then fire its action.
void xgAKValueChanged(i32 handle, i32 node, i32 value)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)256)
        {
        return;
        }
    UXControl* ctl = (UXControl* ?)gAKCtlPeer[handle * (i32)256 + node];
    if (ctl == (UXControl*)0)
        {
        return;
        }
    UXSlider* sl = (UXSlider* ?)ctl;
    if (sl != (UXSlider*)0)
        {
        sl.applyNativeValue(value);
        }
    UXPopUpButton* pu = (UXPopUpButton* ?)ctl;
    if (pu != (UXPopUpButton*)0)
        {
        pu.applyNativeSelection(value);
        }
    UXStepper* stp = (UXStepper* ?)ctl;
    if (stp != (UXStepper*)0)
        {
        stp.applyNativeValue(value);
        }
    UXSegmentedControl* seg = (UXSegmentedControl* ?)ctl;
    if (seg != (UXSegmentedControl*)0)
        {
        seg.applyNativeSelection(value);
        }
    UXToolbar* tbc = (UXToolbar* ?)ctl;
    // value carried the item's tag
    if (tbc != (UXToolbar*)0)
        {
        tbc.applyNativeItemClick(value);
        }
    ctl.fire(); // the app's onChange/action sees the new value
    if (gAKApp != (UXApplication*)0)
        {
        gAKApp.displayIfNeeded();
        if (!gAKApp.isRunning())
            {
            ux_ak_stop();
            }
        }
    }

// A native NSTextField's text changed: find the neutral field (parked in gAKCtlPeer at make time,
// exactly like a button) and fire its onChange.  buf is already synced shim-side.
void xgAKFieldChanged(i32 handle, i32 node)
    {
    if (handle < (i32)0 || handle >= (i32)64 || node < (i32)0 || node >= (i32)256)
        {
        return;
        }
    UXTextField* f = (UXTextField* ?)gAKCtlPeer[handle * (i32)256 + node];
    if (f == (UXTextField*)0)
        {
        return;
        }
    f.fieldDidChange();
    // reflect any live effects
    if (gAKApp != (UXApplication*)0)
        {
        gAKApp.displayIfNeeded();
        }
    }

// Table-data trampolines: the shim's NSTableView datasource calls these with the peer UXTableView
// (stored at make_table time), so the SAME neutral datasource that feeds the GEM subtree feeds the
// native table.  Registered once with the shim (ux_ak_set_table_hooks) in boot.
i32 xgAKTableRows(pointer tbl)
    {
    return ((UXTableView*)tbl).nativeRowCount();
    }
u8* xgAKTableCell(pointer tbl, i32 r, i32 c)
    {
    return ((UXTableView*)tbl).nativeCellText(r, c);
    }
i32 xgAKTableCols(pointer tbl)
    {
    return ((UXTableView*)tbl).numberOfColumns();
    }
u8* xgAKTableColTitle(pointer tbl, i32 c)
    {
    return ((UXTableView*)tbl).columnTitle(c);
    }
i32 xgAKTableColWidth(pointer tbl, i32 c)
    {
    return (i32)((UXTableView*)tbl).columnWidth(c);
    }
i32 xgAKTableMulti(pointer tbl)
    {
    return ((UXTableView*)tbl).nativeAllowsMultiple();
    }
// The NSTableView owns the click UX (ctrl/shift), so it hands us the whole selected set at once.
void xgAKTableSelectSet(pointer tbl, i32* rows, i32 n)
    {
    ((UXTableView*)tbl).applyNativeSelection(rows, n);
    // the delegate may have redrawn
    if (gAKApp != (UXApplication*)0)
        {
        gAKApp.displayIfNeeded();
        }
    }

// NSOutlineView item hooks -> the peer UXOutlineView (item = the app's node, boxed by the shim).
i32 xgAKOutlineChildren(pointer o, pointer item)
    {
    return ((UXOutlineView*)o).nativeChildren(item);
    }
pointer xgAKOutlineChild(pointer o, pointer item, i32 i)
    {
    return ((UXOutlineView*)o).nativeChild(item, i);
    }
i32 xgAKOutlineExpandable(pointer o, pointer item)
    {
    return ((UXOutlineView*)o).nativeExpandable(item);
    }
u8* xgAKOutlineValue(pointer o, pointer item, i32 c)
    {
    return ((UXOutlineView*)o).nativeItemValue(item, c);
    }
void xgAKOutlineDidExpand(pointer o, pointer item, i32 on)
    {
    ((UXOutlineView*)o).nativeDidExpand(item, on);
    }

class UXAppKitDriver : Object<UXViewDriver>
    {
    void init(void)
        {
        }

    // ---- boot ----------------------------------------------------------------
    bool boot(i32* screenW, i32* screenH)
        {
        ux_ak_boot();
        gAKGfx = new UXCocoaGraphics();
        ux_ak_set_table_hooks((pointer)&xgAKTableRows, (pointer)&xgAKTableCell, (pointer)&xgAKTableCols,
                              (pointer)&xgAKTableColTitle, (pointer)&xgAKTableColWidth,
                              (pointer)&xgAKTableMulti, (pointer)&xgAKTableSelectSet);
        ux_ak_set_outline_hooks((pointer)&xgAKOutlineChildren, (pointer)&xgAKOutlineChild,
                                (pointer)&xgAKOutlineExpandable, (pointer)&xgAKOutlineValue,
                                (pointer)&xgAKOutlineDidExpand);
        ux_ak_set_field_hooks((pointer)&xgAKFieldChanged);  // NSTextField edits fire onChange
        ux_ak_set_scroll_content((pointer)&ux_scroll_draw); // a scroll doc view draws its subtree
        screenW[0] = (i32)1440;
        screenH[0] = (i32)900;
        return true;
        }

    // ---- windows -------------------------------------------------------------
    i32 windowCreate(i32 x, i32 y, i32 w, i32 h)
        {
        return ux_ak_window_create(x, y, w, h);
        }
    void windowSetContent(i32 handle, pointer fn, pointer ud)
        {
        ux_ak_window_set_content(handle, fn, ud);
        }
    void windowOpen(i32 handle, i32 x, i32 y, i32 w, i32 h)
        {
        ux_ak_window_open(handle);
        }
    void windowDestroy(i32 handle)
        {
        ux_ak_window_close(handle);
        }
    void windowOrderFront(i32 handle)
        {
        ux_ak_window_front(handle);
        }
    bool hasNativeFileOpen(void)
        {
        return true;
        }
    i32 fileOpen(u8* prompt, u8* startDir, u8* out, i32 outCap)
        {
        return ux_ak_open_panel(prompt, startDir, out, outCap);
        }
    bool hasNativeColorPicker(void)
        {
        return true;
        }
    i32 pickColor(i32 r, i32 g, i32 b, i32* outR, i32* outG, i32* outB)
        {
        return ux_ak_color_panel(r, g, b, outR, outG, outB);
        }
    bool hasNativeFontPicker(void)
        {
        return true;
        }
    i32 pickFont(u8* inF, i32 inS, i32 inB, i32 inI, u8* outF, i32 cap, i32* outS, i32* outB, i32* outI)
        {
        return ux_ak_font_panel(inF, inS, inB, inI, outF, cap, outS, outB, outI);
        }
    i32 nowMs(void)
        {
        return ux_ak_now_ms();
        }
    void nowUTC(i32* out7)
        {
        ux_ak_now_utc(out7);
        }
    i32 localOffsetMinutes(void)
        {
        return ux_ak_local_offset_minutes();
        }
    // Settings are NSUserDefaults — a suite per domain, the standard suite for the shared one, so a
    // preference UXKit saves is `defaults read`-able like any other app's.  NOTE the one asymmetry with
    // the other backends: the shared domain is machine-wide on XTOS and Win32 but APP-wide here,
    // because macOS's machine-wide equivalent is NSGlobalDomain and a toolkit has no business
    // writing to it.  (Reads still see it: the standard suite falls back to NSGlobalDomain itself.)
    bool settingGet(u8* domain, u8* key, u8* out, i32 cap)
        {
        return ux_ak_setting_get(domain, key, out, cap) != (i32)0;
        }
    bool settingSet(u8* domain, u8* key, u8* value)
        {
        return ux_ak_setting_set(domain, key, value) != (i32)0;
        }
    bool settingRemove(u8* domain, u8* key)
        {
        return ux_ak_setting_remove(domain, key) != (i32)0;
        }
    i32 textWidth(u8* s, i32 size)
        {
        return ux_ak_text_width(s, size);
        }
    i32 textWidthStyled(u8* s, u8* family, i32 size, bool bold, bool italic)
        {
        return ux_ak_text_width_font(s, family, size, bold ? (i32)1 : (i32)0, italic ? (i32)1 : (i32)0);
        }
    // NSPopUpButton pops its own menu and reports back through applyNativeSelection — nothing to run here.
    i32 runPopupMenu(pointer peer, i32 x, i32 y)
        {
        return (i32)-1;
        }
    // Family list for the toolkit chooser (protocol conformance — macOS presents the native NSFontPanel,
    // so the toolkit chooser is not shown here; kept complete for when it is exercised in tests).
    u8* akFamily(i32 i)
        {
        if (i == (i32)0)
            {
            return (u8*)"Helvetica";
            }
        if (i == (i32)1)
            {
            return (u8*)"Times";
            }
        if (i == (i32)2)
            {
            return (u8*)"Courier";
            }
        if (i == (i32)3)
            {
            return (u8*)"Georgia";
            }
        if (i == (i32)4)
            {
            return (u8*)"Verdana";
            }
        if (i == (i32)5)
            {
            return (u8*)"Menlo";
            }
        if (i == (i32)6)
            {
            return (u8*)"Palatino";
            }
        if (i == (i32)7)
            {
            return (u8*)"Optima";
            }
        if (i == (i32)8)
            {
            return (u8*)"Futura";
            }
        return (u8*)"Baskerville";
        }
    i32 fontFamilyCount(void)
        {
        return (i32)10;
        }
    i32 fontFamilyName(i32 idx, u8* out, i32 cap)
        {
        if (idx < (i32)0 || idx >= (i32)10)
            {
            return (i32)-1;
            }
        u8* nm = self.akFamily(idx);
        i32 i = (i32)0;
        while (nm[i] != (u8)0 && i < cap - (i32)1)
            {
            out[i] = nm[i];
            i = i + (i32)1;
            }
        out[i] = (u8)0;
        return i;
        }
    // Drive the NSScrollView the toolkit's UXScrollView maps to.  The offset lives in the clip view;
    // the document view is flipped, so px is from the top like everything else the toolkit measures.
    void nativeScrollTo(pointer h, i32 node, i32 px)
        {
        ux_ak_scroll_set(((AKTree*)h).win, node, px);
        }
    i32 nativeScrollPx(pointer h, i32 node)
        {
        return ux_ak_scroll_get(((AKTree*)h).win, node);
        }
    // native panel reads the FS itself
    i32 listDir(u8* path, u8* out, i32 outCap)
        {
        return (i32)-1;
        }
    // (unused — AppKit uses NSOpenPanel)
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
    void windowSetTitle(i32 handle, u8* s)
        {
        ux_ak_window_set_title(handle, s);
        }
    void windowSetSubtitle(i32 handle, u8* s)
        {
        ux_ak_window_set_subtitle(handle, s);
        }
    // No AppKit equivalent for these two.  The AES's info LINE is a strip of text below the title bar
    // that macOS simply does not have (a toolbar or an accessory view is the idiom, and neither is
    // this call's shape); the icon is a GEM icon SLICE, which is not an image AppKit could load.
    // No-ops on purpose, unlike before, when all four were no-ops by omission.
    void windowSetInfo(i32 handle, u8* s)
        {
        }
    void windowSetIcon(i32 handle, u8* slice)
        {
        }
    void windowSetModified(i32 handle, bool m)
        {
        ux_ak_window_set_modified(handle, m ? (i32)1 : (i32)0);
        }
    // Scrolling via a native NSScrollView: report the content extent (the document view grows to it,
    // NSScrollView scrolls it), and let NSScrollView own the offset.  scrollX/Y return 0 so the
    // neutral layoutFor does NOT also shift the tree (that would double the offset) — the tree draws
    // at absolute positions and NSScrollView moves it.  Hit-testing still "scrolls for free" because
    // clicks reach the document view already in scrolled (document) coordinates.
    void windowContentSize(i32 handle, i32 w, i32 h)
        {
        ux_ak_content_size(handle, w, h);
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
        ux_ak_set_scroll(handle, x, y);
        }
    void windowContentGeometry(i32 handle, i32* w, i32* h)
        {
        ux_ak_content_geometry(handle, w, h);
        }
    void windowInvalidate(i32 handle)
        {
        ux_ak_window_invalidate(handle);
        }
    void windowInvalidateRect(i32 handle, i32 x, i32 y, i32 w, i32 h)
        {
        self.windowInvalidate(handle);
        }
    // The window that actually received the NSEvent, not a guess from coordinates: ak_mouseDown
    // resolves its content view to a handle and hands it in, so multi-window mouse routing is exact.
    // (The coords in the event are already local to that window, which is what dispatchMouse wants.)
    i32 windowAtPoint(i32 x, i32 y)
        {
        return gAKMouseWin != (i32)0 ? gAKMouseWin : (i32)1;
        }
    // Native tables own their own drag-select, but a toolkit-drawn drag (a split divider) needs a modal
    // step: pull the next NSEvent mouse-dragged/up.  (Tables never call this — they route through AppKit.)
    i32 trackDragStep(i32* x, i32* y)
        {
        // see gInputReplay (UXEvent.xc)
        if (gInputReplay)
            {
            return (i32)0;
            }
        return ux_ak_drag_next(x, y);
        }

    // ---- the shadow tree (pure data structure — shared shape with UXWin32Driver) --------------
    pointer structNew(void)
        {
        AKTree* t = (AKTree*)malloc((u32)sizeof(AKTree));
        t.cap = (i32)16;
        t.count = (i32)0;
        t.nodes = (AKNode*)calloc((u32)t.cap, (u32)sizeof(AKNode));
        return (pointer)t;
        }
    void structFree(pointer h)
        {
        if (h == (pointer)0)
            {
            return;
            }
        AKTree* t = (AKTree*)h;
        if (t.nodes != (AKNode*)0)
            {
            free((pointer)t.nodes);
            }
        free(h);
        }
    // no .rsc on AppKit (yet)
    void structAdopt(pointer h, pointer t, i32 n)
        {
        }
    pointer structObjects(pointer h)
        {
        return h;
        }
    i32 structLength(pointer h)
        {
        return ((AKTree*)h).count;
        }

    void structGrow(pointer h, i32 want)
        {
        AKTree* t = (AKTree*)h;
        if (want <= t.cap)
            {
            return;
            }
        i32 cap = t.cap;
        while (cap < want)
            {
            cap = cap * (i32)2;
            }
        t.nodes = (AKNode*)realloc((pointer)t.nodes, (u32)cap * (u32)sizeof(AKNode));
        t.cap = cap;
        }
    i32 structAppend(pointer h, i32 kind, i32 x, i32 y, i32 w, i32 ht)
        {
        AKTree* t = (AKTree*)h;
        self.structGrow(h, t.count + (i32)1);
        i32 i = t.count;
        AKNode* n = &t.nodes[i];
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
        n.autoresize = (i32)0;
        n.spec = (pointer)0;
        n.next = (i16)-1;
        n.head = (i16)-1;
        n.tail = (i16)-1;
        n.parent = (i16)-1;
        n.peer = (pointer)0; // grown trees are raw realloc memory — garbage
                             // here becomes a fire-by-peer jump through junk
        t.count = i + (i32)1;
        return i;
        }
    void structAddChild(pointer h, i32 parent, i32 child)
        {
        AKNode* t = ((AKTree*)h).nodes;
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
        AKNode* t = ((AKTree*)h).nodes;
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

    // Move the native control NOW, as gtk/ios/android already do.  AppKit and
    // Win32 wrote only the shadow tree and left the real move to the next
    // realizeTree, which setFrame does not trigger — so a programmatic move
    // appeared to do nothing until some unrelated redraw happened to rebuild.
    // A control under an autoresize mask is skipped: AppKit owns its placement
    // once masked, and re-setting the frame here fights the live track (the
    // same rule realizeTree follows).
    void structSetFrame(pointer h, i32 i, i32 x, i32 y, i32 w, i32 ht)
        {
        AKTree* t = (AKTree*)h;
        AKNode* n = &t.nodes[i];
        n.x = (i16)x;
        n.y = (i16)y;
        n.w = (i16)w;
        n.h = (i16)ht;
        if (t.win > (i32)0 && n.autoresize == (i32)0 && ux_ak_has_control(t.win, i) != (i32)0)
            {
            i32 ax = (i32)0;
            i32 ay = (i32)0;
            i32 aw = (i32)0;
            i32 ah = (i32)0;
            self.structAbsFrame(h, i, &ax, &ay, &aw, &ah);
            ux_ak_set_control_frame(t.win, i, ax, ay, aw, ah);
            }
        }
    void structFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
        {
        AKNode* n = &((AKTree*)h).nodes[i];
        x[0] = (i32)n.x;
        y[0] = (i32)n.y;
        w[0] = (i32)n.w;
        ht[0] = (i32)n.h;
        }
    // Setting hidden must reach the DESCENDANTS' native controls immediately,
    // not at some later realize: an editor hides a pane and expects it gone on
    // the next paint.  The subtree walk is bounded by the node count, so a
    // malformed tree cannot spin.
    void structSetHidden(pointer h, i32 i, i32 on)
        {
        AKTree* t = (AKTree*)h;
        t.nodes[i].hidden = (i16)on;
        if (t.win > (i32)0)
            {
            self.pushHiddenSubtree(h, i);
            }
        }
    void pushHiddenSubtree(pointer h, i32 i)
        {
        AKTree* t = (AKTree*)h;
        if (i < (i32)0 || i >= t.count)
            {
            return;
            }
        if (ux_ak_has_control(t.win, i) != (i32)0)
            {
            ux_ak_set_control_hidden(t.win, i, self.effectiveHidden(h, i));
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

    // HIDDEN IS INHERITED.  A native control is its own NSView, positioned
    // absolutely, so it does not disappear just because an ancestor did — the
    // app-drawn walk skips a hidden subtree (see drawOne) but a real NSButton
    // has no idea its container went away.  Asking the question of the whole
    // ancestor chain is what makes "hide this pane" mean the same thing for
    // drawn content and native controls, which is what UXTabView and any
    // editor swapping one form for another both rely on.
    // Node 0 is the root.  Walking parents must reach it; hitting -1 first
    // means this node was removed from the tree and is merely still occupying
    // its slot in the array.
    i32 isDetached(pointer h, i32 i)
        {
        AKNode* t = ((AKTree*)h).nodes;
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
        AKNode* t = ((AKTree*)h).nodes;
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
    i32 structIsHidden(pointer h, i32 i)
        {
        return (i32)((AKTree*)h).nodes[i].hidden;
        }
    // Push to the native control immediately, as structSetHidden does and as
    // the win32/gtk/ios/android drivers already did.  AppKit was the only one
    // that just set the shadow flag and waited for a realize pass that
    // setEnabled does not trigger — so re-enabling a native control did
    // nothing visible until something else happened to rebuild the tree.
    // Not inherited: disabling a container does not disable its children,
    // matching AppKit itself and the other four drivers.  Hidden is inherited
    // because an invisible parent genuinely cannot show a visible child;
    // enabled has no such implication.
    // What the NATIVE control actually reports, for gates that must
    // distinguish "the flag was set" from "the control changed".  -1 = no
    // native control for that node.
    i32 controlEnabled(pointer h, i32 i)
        {
        AKTree* t = (AKTree*)h;
        if (t.win <= (i32)0)
            {
            return (i32)-1;
            }
        return ux_ak_control_enabled(t.win, i);
        }

    // What the NATIVE toggle actually shows; see controlEnabled.  A radio whose
    // peer says "selected" while the NSButton still reads off is exactly the
    // failure a shadow-only assertion cannot see.
    i32 controlChecked(pointer h, i32 i)
        {
        AKTree* t = (AKTree*)h;
        if (t.win <= (i32)0)
            {
            return (i32)-1;
            }
        return ux_ak_control_check(t.win, i);
        }

    // What the NATIVE control's frame actually is; see controlEnabled.
    i32 controlFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
        {
        AKTree* t = (AKTree*)h;
        if (t.win <= (i32)0)
            {
            return (i32)0;
            }
        return ux_ak_control_frame(t.win, i, x, y, w, ht);
        }

    void structSetEnabled(pointer h, i32 i, i32 on)
        {
        AKTree* t = (AKTree*)h;
        t.nodes[i].enabled = (i16)on;
        if (t.win > (i32)0 && ux_ak_has_control(t.win, i) != (i32)0)
            {
            ux_ak_set_control_enabled(t.win, i, on);
            }
        }
    i32 structIsEnabled(pointer h, i32 i)
        {
        return (i32)((AKTree*)h).nodes[i].enabled;
        }
    void structSetSelected(pointer h, i32 i, i32 on)
        {
        ((AKTree*)h).nodes[i].selected = (i16)on;
        }
    i32 structIsSelected(pointer h, i32 i)
        {
        return (i32)((AKTree*)h).nodes[i].selected;
        }
    void structSetClips(pointer h, i32 i, i32 on)
        {
        ((AKTree*)h).nodes[i].clips = (i16)on;
        }
    void structSetSpec(pointer h, i32 i, pointer spec)
        {
        ((AKTree*)h).nodes[i].spec = spec;
        }
    // A table node's spec is otherwise unused on AppKit (a box draws no text), so park the peer
    // UXTableView here — realizeTree reads it back to drive the native NSTableView.
    // NOT spec (title lives there)
    void structSetPeer(pointer h, i32 i, pointer peer)
        {
        ((AKTree*)h).nodes[i].peer = peer;
        }
    void structSetAutoresize(pointer h, i32 i, i32 mask)
        {
        ((AKTree*)h).nodes[i].autoresize = mask;
        }
    // NSView autoresizing tracks it live
    bool driverAutoresizes(void)
        {
        return true;
        }
    void structSetSelectable(pointer h, i32 i, i32 on)
        {
        ((AKTree*)h).nodes[i].selectable = (i16)on;
        }
    void structSetEditable(pointer h, i32 i, i32 on)
        {
        ((AKTree*)h).nodes[i].editable = (i16)on;
        }

    void treeOffset(pointer tree, i32 obj, i32* ax, i32* ay)
        {
        ax[0] = (i32)0;
        ay[0] = (i32)0;
        }
    void structAbsFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
        {
        AKNode* t = ((AKTree*)h).nodes;
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

    // Deepest visible node whose ABSOLUTE rect contains (px,py), or -1.
    i32 hitOne(AKNode* t, i32 i, i32 ox, i32 oy, i32 px, i32 py)
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
        // never deref null
        if (tree == (pointer)0 || ((AKTree*)tree).nodes == (AKNode*)0)
            {
            return (i32)-1;
            }
        return self.hitOne(((AKTree*)tree).nodes, start, (i32)0, (i32)0, x, y);
        }

    // Native NSControls exist when the GUI is interactive OR the capture booth
    // asked for them (headless portraits) — ONE predicate for realize + draw,
    // so the two can never disagree about who paints a widget.
    i32 nativeUI(void)
        {
        return ux_ak_interactive() != (i32)0 || ux_ak_capture() != (i32)0 ? (i32)1 : (i32)0;
        }

    // ---- painting ------------------------------------------------------------
    void treeSetUserDraw(pointer fn, pointer ud)
        {
        gAKUserFn = fn;
        gAKUserUd = ud;
        }
    // Walk the shadow tree; a custom view calls back into drawRect via the userdraw callback, and a
    // stock widget is drawn by the driver (the AppKit analogue of GEM's native widget art).
    void drawOne(AKTree* t, i32 i)
        {
        if (i < (i32)0 || t.nodes[i].hidden != (i16)0)
            {
            return;
            }
        i32 k = t.nodes[i].kind;
        // A native NSTableView (realizeTree) covers the table's whole area interactively, so don't
        // draw the box or recurse into its rows/cells; headless falls through and draws the subtree.
        if (k == (i32)UXKindTable && self.nativeUI() != (i32)0)
            {
            return;
            }
        // A native NSScrollView (realizeTree) overlays the scroll view's whole area and draws its
        // document subtree into its own surface, so don't also draw it inline here.
        if (k == (i32)UXKindScroll && self.nativeUI() != (i32)0)
            {
            return;
            }
        // Interactive: check boxes / radios are native NSButtons (realizeTree), so don't also app-draw
        // the diamond under them.  Headless still draws them (the seam below).
        if ((k == (i32)UXKindCheckbox || k == (i32)UXKindRadio) && self.nativeUI() != (i32)0)
            {
            return;
            }
        // native NSSlider overlays
        if (k == (i32)UXKindSlider && self.nativeUI() != (i32)0)
            {
            return;
            }
        // native NSPopUpButton overlays
        if (k == (i32)UXKindPopup && self.nativeUI() != (i32)0)
            {
            return;
            }
        // native NSStepper overlays
        if (k == (i32)UXKindStepper && self.nativeUI() != (i32)0)
            {
            return;
            }
        // native NSSegmentedControl overlays
        if (k == (i32)UXKindSegmented && self.nativeUI() != (i32)0)
            {
            return;
            }
        // native NSProgressIndicator overlays
        if (k == (i32)UXKindProgress && self.nativeUI() != (i32)0)
            {
            return;
            }
        // Native NSToolbar is WINDOW CHROME — invisible to a content cache, so
        // the capture booth app-draws the fallback instead of showing nothing.
        if (k == (i32)UXKindToolbar && self.nativeUI() != (i32)0 && ux_ak_capture() == (i32)0)
            {
            return;
            }
        // A SHIELD is app-drawn too: it intercepts input, it is not invisible.  Leaving it
        // out of this list is subtle -- the shield keeps working and its drawRect silently
        // stops being called, so an overlay that draws alignment guides goes blank.
        if ((k == (i32)UXKindView || k == (i32)UXKindShield || k == (i32)UXKindCheckbox || k == (i32)UXKindRadio || k == (i32)UXKindToolbar) && gAKUserFn != (pointer)0)
            {
            UXUserDrawFn* f = (UXUserDrawFn*)gAKUserFn; // checkbox/radio: app-drawn on AppKit (no native art yet)
            f((pointer)t.nodes, i, gAKUserUd);
            }
        else if (k == (i32)UXKindButton)
            {
            // Interactive mode overlays a real NSButton (see realizeTree), so don't draw an
            // imitation; headless still draws (the pixel tests check it).
            if (self.nativeUI() == (i32)0)
                {
                i32 ax = (i32)0;
                i32 ay = (i32)0;
                i32 w = (i32)0;
                i32 hh = (i32)0;
                self.structAbsFrame((pointer)t, i, &ax, &ay, &w, &hh);
                ux_ak_fill(ax, ay, w, hh, (i32)192, (i32)192, (i32)192); // raised grey box
                if (t.nodes[i].spec != (pointer)0)
                    {
                    i32 c = t.nodes[i].enabled != (i16)0 ? (i32)0 : (i32)128; // black / grey if disabled
                    ux_ak_text((u8*)t.nodes[i].spec, ax + (i32)6, ay + (i32)3, c, c, c, (i32)12);
                    }
                }
            }
        else if (k == (i32)UXKindField)
            {
            // native NSTextField when GUI
            if (self.nativeUI() == (i32)0)
                {
                i32 ax = (i32)0;
                i32 ay = (i32)0;
                i32 w = (i32)0;
                i32 hh = (i32)0;
                self.structAbsFrame((pointer)t, i, &ax, &ay, &w, &hh);
                ux_ak_fill(ax, ay, w, hh, (i32)255, (i32)255, (i32)255); // white field box
                AKField* f = (AKField*)t.nodes[i].spec;
                if (f != (AKField*)0 && f.buf[0] != (u8)0)
                    {
                    ux_ak_text(f.buf, ax + (i32)3, ay + (i32)2, (i32)0, (i32)0, (i32)0, (i32)12);
                    }
                }
            }
        else if (k == (i32)UXKindLabel && t.nodes[i].spec != (pointer)0)
            {
            // native label when GUI
            if (self.nativeUI() == (i32)0)
                {
                i32 ax = (i32)0;
                i32 ay = (i32)0;
                i32 w = (i32)0;
                i32 hh = (i32)0;
                self.structAbsFrame((pointer)t, i, &ax, &ay, &w, &hh);
                ux_ak_text((u8*)t.nodes[i].spec, ax + (i32)2, ay + (i32)2, (i32)0, (i32)0, (i32)0, (i32)12);
                }
            }
        i16 c = t.nodes[i].head;
        while (c >= (i16)0)
            {
            self.drawOne(t, (i32)c);
            c = t.nodes[c].next;
            }
        }
    void treeDraw(pointer tree, i32 start, i32 clx, i32 cly, i32 clw, i32 clh)
        {
        self.drawOne((AKTree*)tree, start);
        }
    UXGraphics* beginViewDraw(i32 ax, i32 ay, i32 aw, i32 ah)
        {
        gAKGfx.bind(UXGeom.make((i16)(ax - gAKDrawOX), (i16)(ay - gAKDrawOY), (i16)aw, (i16)ah));
        return gAKGfx;
        }
    void setDrawOffset(i32 x, i32 y)
        {
        gAKDrawOX = x;
        gAKDrawOY = y;
        }
    // NSScrollView owns the offset
    bool scrollsNatively(void)
        {
        return true;
        }

    // True if any ancestor of node i is a table: its rows/cells belong to the native NSTableView,
    // so they must NOT also be realized as standalone native labels.
    i32 isUnderTable(AKTree* t, i32 i)
        {
        i16 p = t.nodes[i].parent;
        while (p >= (i16)0)
            {
            if ((i32)t.nodes[p].kind == (i32)UXKindTable)
                {
                return (i32)1;
                }
            p = t.nodes[p].parent;
            }
        return (i32)0;
        }

    // Native controls (interactive only): reconcile real NSButton/NSTextField/NSTableView subviews
    // with the tree's control nodes — create the missing ones on the window's content view,
    // reposition/re-state the rest.  Called from UXWindow.displayAll (outside the draw), so no
    // re-entrant view mutation.  Headless is a no-op — the controls are drawn (see drawOne).
    // Read a checkbox's / radio's checked state from its neutral peer widget.
    // A control's text alignment, read from its PEER.  Alignment lives on the
    // control rather than in the shadow tree, so this is the read that carries
    // it to the native widget -- the same shape as toggleState below.
    i32 alignOf(pointer peer)
        {
        UXControl* c = (UXControl* ?)peer;
        if (c == (UXControl*)0)
            {
            return (i32)UX_ALIGN_LEFT;
            }
        return c.alignment();
        }
    // What the NATIVE control's alignment actually is; see controlEnabled.
    i32 controlAlign(pointer h, i32 i)
        {
        AKTree* t = (AKTree*)h;
        if (t.win <= (i32)0)
            {
            return (i32)-1;
            }
        return ux_ak_control_align(t.win, i);
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
        if (self.nativeUI() == (i32)0)
            {
            return;
            }
        AKTree* t = (AKTree*)tree;
        t.win = handle; // so a later tree-only op can still find its controls
        for (i32 i = (i32)0; i < t.count; i = i + (i32)1)
            {
            i32 k = (i32)t.nodes[i].kind;
            if (k == (i32)UXKindShield)
                {
                // A bare native view above everything, so a press on a design
                // surface reaches the toolkit rather than the control under it.
                i32 ax = (i32)0;
                i32 ay = (i32)0;
                i32 w = (i32)0;
                i32 hh = (i32)0;
                self.structAbsFrame(tree, i, &ax, &ay, &w, &hh);
                ux_ak_make_shield(handle, ax, ay, w, hh, self.effectiveHidden(tree, i));
                }
            else if (k == (i32)UXKindCheckbox || k == (i32)UXKindRadio)
                {
                // A native NSButton switch/radio.  Title is in spec; the checked/selected state comes
                // from the peer widget every display (the neutral UXCheckbox/UXRadioGroup owns it).
                i32 ax = (i32)0;
                i32 ay = (i32)0;
                i32 w = (i32)0;
                i32 hh = (i32)0;
                self.structAbsFrame(tree, i, &ax, &ay, &w, &hh);
                i32 on = self.toggleState(t.nodes[i].peer, k);
                if (ux_ak_has_control(handle, i) == (i32)0)
                    {
                    u8* title = t.nodes[i].spec != (pointer)0 ? (u8*)t.nodes[i].spec : (u8*)"";
                    i32 flags = on | (k == (i32)UXKindRadio ? (i32)2 : (i32)0);
                    ux_ak_make_check(handle, i, ax, ay, w, hh, title, flags);
                    gAKCtlPeer[handle * (i32)256 + i] = t.nodes[i].peer;
                    ux_ak_set_control_autoresize(handle, i, (i32)t.nodes[i].autoresize);
                    }
                else
                    {
                    if ((i32)t.nodes[i].autoresize == (i32)0)
                        {
                        ux_ak_set_control_frame(handle, i, ax, ay, w, hh);
                        }
                    ux_ak_set_control_check(handle, i, on);
                    }
                ux_ak_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                }
            else if (k == (i32)UXKindSlider)
                {
                // A native NSSlider: the peer UXSlider owns min/max/value; drags flow back via xgAKValueChanged.
                i32 ax = (i32)0;
                i32 ay = (i32)0;
                i32 w = (i32)0;
                i32 hh = (i32)0;
                self.structAbsFrame(tree, i, &ax, &ay, &w, &hh);
                UXSlider* sv = (UXSlider* ?)t.nodes[i].peer;
                if (sv != (UXSlider*)0)
                    {
                    if (ux_ak_has_control(handle, i) == (i32)0)
                        {
                        ux_ak_make_slider(handle, i, ax, ay, w, hh, sv.nativeMin(), sv.nativeMax(), sv.nativeValue());
                        gAKCtlPeer[handle * (i32)256 + i] = t.nodes[i].peer;
                        ux_ak_set_control_autoresize(handle, i, (i32)t.nodes[i].autoresize);
                        }
                    else
                        {
                        if ((i32)t.nodes[i].autoresize == (i32)0)
                            {
                            ux_ak_set_control_frame(handle, i, ax, ay, w, hh);
                            }
                        ux_ak_set_slider_value(handle, i, sv.nativeValue());
                        }
                    ux_ak_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                    }
                }
            else if (k == (i32)UXKindPopup)
                {
                // A native NSPopUpButton: build once with its items; selection syncs each display.
                i32 ax = (i32)0;
                i32 ay = (i32)0;
                i32 w = (i32)0;
                i32 hh = (i32)0;
                self.structAbsFrame(tree, i, &ax, &ay, &w, &hh);
                UXPopUpButton* pv = (UXPopUpButton* ?)t.nodes[i].peer;
                if (pv != (UXPopUpButton*)0)
                    {
                    if (ux_ak_has_control(handle, i) == (i32)0)
                        {
                        ux_ak_make_popup(handle, i, ax, ay, w, hh);
                        for (i32 j = (i32)0; j < pv.nativeItemCount(); j = j + (i32)1)
                            {
                            ux_ak_popup_add_item(handle, i, pv.nativeItemTitle(j));
                            }
                        ux_ak_popup_select(handle, i, pv.nativeSelected());
                        gAKCtlPeer[handle * (i32)256 + i] = t.nodes[i].peer;
                        ux_ak_set_control_autoresize(handle, i, (i32)t.nodes[i].autoresize);
                        }
                    else
                        {
                        if ((i32)t.nodes[i].autoresize == (i32)0)
                            {
                            ux_ak_set_control_frame(handle, i, ax, ay, w, hh);
                            }
                        ux_ak_popup_select(handle, i, pv.nativeSelected());
                        }
                    ux_ak_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                    }
                }
            else if (k == (i32)UXKindStepper)
                {
                i32 ax = (i32)0;
                i32 ay = (i32)0;
                i32 w = (i32)0;
                i32 hh = (i32)0;
                self.structAbsFrame(tree, i, &ax, &ay, &w, &hh);
                UXStepper* sv = (UXStepper* ?)t.nodes[i].peer;
                if (sv != (UXStepper*)0)
                    {
                    if (ux_ak_has_control(handle, i) == (i32)0)
                        {
                        ux_ak_make_stepper(handle, i, ax, ay, w, hh, sv.nativeMin(), sv.nativeMax(), sv.nativeStep(), sv.nativeWraps() ? (i32)1 : (i32)0, sv.nativeValue());
                        gAKCtlPeer[handle * (i32)256 + i] = t.nodes[i].peer;
                        ux_ak_set_control_autoresize(handle, i, (i32)t.nodes[i].autoresize);
                        }
                    else
                        {
                        if ((i32)t.nodes[i].autoresize == (i32)0)
                            {
                            ux_ak_set_control_frame(handle, i, ax, ay, w, hh);
                            }
                        ux_ak_set_stepper_value(handle, i, sv.nativeValue());
                        }
                    ux_ak_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                    }
                }
            else if (k == (i32)UXKindSegmented)
                {
                i32 ax = (i32)0;
                i32 ay = (i32)0;
                i32 w = (i32)0;
                i32 hh = (i32)0;
                self.structAbsFrame(tree, i, &ax, &ay, &w, &hh);
                UXSegmentedControl* gv = (UXSegmentedControl* ?)t.nodes[i].peer;
                if (gv != (UXSegmentedControl*)0)
                    {
                    if (ux_ak_has_control(handle, i) == (i32)0)
                        {
                        ux_ak_make_segmented(handle, i, ax, ay, w, hh, gv.nativeSegCount());
                        for (i32 j = (i32)0; j < gv.nativeSegCount(); j = j + (i32)1)
                            {
                            ux_ak_seg_set_label(handle, i, j, gv.nativeSegLabel(j));
                            }
                        ux_ak_seg_select(handle, i, gv.nativeSelectedSeg());
                        gAKCtlPeer[handle * (i32)256 + i] = t.nodes[i].peer;
                        ux_ak_set_control_autoresize(handle, i, (i32)t.nodes[i].autoresize);
                        }
                    else
                        {
                        if ((i32)t.nodes[i].autoresize == (i32)0)
                            {
                            ux_ak_set_control_frame(handle, i, ax, ay, w, hh);
                            }
                        ux_ak_seg_select(handle, i, gv.nativeSelectedSeg());
                        }
                    ux_ak_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                    }
                }
            else if (k == (i32)UXKindProgress)
                {
                i32 ax = (i32)0;
                i32 ay = (i32)0;
                i32 w = (i32)0;
                i32 hh = (i32)0;
                self.structAbsFrame(tree, i, &ax, &ay, &w, &hh);
                UXProgressBar* pgv = (UXProgressBar* ?)t.nodes[i].peer;
                if (pgv != (UXProgressBar*)0)
                    {
                    if (ux_ak_has_control(handle, i) == (i32)0)
                        {
                        ux_ak_make_progress(handle, i, ax, ay, w, hh);
                        gAKCtlPeer[handle * (i32)256 + i] = t.nodes[i].peer;
                        ux_ak_set_control_autoresize(handle, i, (i32)t.nodes[i].autoresize);
                        }
                    else if ((i32)t.nodes[i].autoresize == (i32)0)
                        {
                        ux_ak_set_control_frame(handle, i, ax, ay, w, hh);
                        }
                    ux_ak_set_progress(handle, i, pgv.nativeFractionMille(), pgv.nativeIndeterminate());
                    ux_ak_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                    }
                }
            else if (k == (i32)UXKindToolbar && ux_ak_capture() == (i32)0)
                {
                // A native NSToolbar (window chrome): built once from the peer's items; no subview.
                UXToolbar* tv = (UXToolbar* ?)t.nodes[i].peer;
                if (tv != (UXToolbar*)0 && gAKCtlPeer[handle * (i32)256 + i] == (pointer)0)
                    {
                    ux_ak_toolbar_begin(handle, i);
                    for (i32 j = (i32)0; j < tv.nativeItemCount(); j = j + (i32)1)
                        {
                        ux_ak_toolbar_add(handle, i, tv.nativeItemTag(j), tv.nativeItemLabel(j), tv.nativeItemType(j));
                        }
                    ux_ak_toolbar_install(handle, i);
                    gAKCtlPeer[handle * (i32)256 + i] = t.nodes[i].peer; // realized-flag + click-routing peer
                    }
                }
            else if (k == (i32)UXKindTable)
                {
                i32 ax = (i32)0;
                i32 ay = (i32)0;
                i32 w = (i32)0;
                i32 hh = (i32)0;
                self.structAbsFrame(tree, i, &ax, &ay, &w, &hh);
                i32 outline = ((UXTableView*)t.nodes[i].peer).nativeIsOutline(); // tree vs flat list
                if (ux_ak_has_control(handle, i) == (i32)0)
                    {
                    if (outline != (i32)0)
                        {
                        ux_ak_make_outline(handle, i, ax, ay, w, hh, t.nodes[i].peer);
                        }
                    else
                        {
                        ux_ak_make_table(handle, i, ax, ay, w, hh, t.nodes[i].peer);
                        }
                    }
                else
                    {
                    ux_ak_set_control_frame(handle, i, ax, ay, w, hh);
                    if (outline != (i32)0)
                        {
                        ux_ak_outline_reload(handle, i);
                        }
                    else
                        {
                        ux_ak_table_reload(handle, i);
                        // A selection the MODEL made (a replay, or app code) has to be sent the other
                        // way: the NSTableView is the visible truth and never reads the model back.
                        UXTableView* tvp = (UXTableView* ?)t.nodes[i].peer;
                        if (tvp != (UXTableView*)0 && tvp.nativeSelectionNeedsPush())
                            {
                            i32 rows[256];
                            i32 n = tvp.selectedRowList(&rows[(i32)0], (i32)256);
                            ux_ak_table_select(handle, i, &rows[(i32)0], n);
                            tvp.clearNativeSelectionPush();
                            }
                        }
                    }
                ux_ak_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                }
            else if (k == (i32)UXKindScroll && self.isUnderTable(t, i) == (i32)0)
                {
                // A table/outline's OWN scroll child must NOT become a native NSScrollView: the native
                // NSTableView/NSOutlineView already overlays this subtree and provides its own scrolling.
                // Realizing one here (regressed by the native-scroll commit) drew an empty scroll ON TOP
                // of the outline, stealing its clicks (no disclosure) and hiding its selection.  bug 020.
                i32 ax = (i32)0;
                i32 ay = (i32)0;
                i32 w = (i32)0;
                i32 hh = (i32)0;
                self.structAbsFrame(tree, i, &ax, &ay, &w, &hh);
                i32 ch = ((UXScrollView*)t.nodes[i].peer).nativeContentHeight();
                if (ux_ak_has_control(handle, i) == (i32)0)
                    {
                    ux_ak_make_scroll(handle, i, ax, ay, w, hh, ch, t.nodes[i].peer);
                    }
                else
                    {
                    ux_ak_set_control_frame(handle, i, ax, ay, w, hh);
                    ux_ak_scroll_reload(handle, i, ch);
                    }
                ux_ak_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                }
            else if ((k == (i32)UXKindButton || k == (i32)UXKindField || k == (i32)UXKindLabel) && self.isUnderTable(t, i) == (i32)0)
                {
                i32 ax = (i32)0;
                i32 ay = (i32)0;
                i32 w = (i32)0;
                i32 hh = (i32)0;
                self.structAbsFrame(tree, i, &ax, &ay, &w, &hh);
                i32 mask = (i32)t.nodes[i].autoresize;
                if (ux_ak_has_control(handle, i) == (i32)0)
                    {
                    if (k == (i32)UXKindButton)
                        {
                        u8* title = t.nodes[i].spec != (pointer)0 ? (u8*)t.nodes[i].spec : (u8*)"";
                        ux_ak_make_button(handle, i, ax, ay, w, hh, title);
                        gAKCtlPeer[handle * (i32)256 + i] = t.nodes[i].peer;
                        }
                    else if (k == (i32)UXKindField)
                        {
                        AKField* f = (AKField*)t.nodes[i].spec;
                        u8* buf = f != (AKField*)0 ? f.buf : (u8*)0;
                        i32 cap = f != (AKField*)0 ? f.cap : (i32)0;
                        i32 sec = f != (AKField*)0 ? f.secure : (i32)0;
                        ux_ak_make_field(handle, i, ax, ay, w, hh, buf, cap, sec);
                        gAKCtlPeer[handle * (i32)256 + i] = t.nodes[i].peer; // so onChange can find the field
                        if (f != (AKField*)0 && f.place != (u8*)0)
                            {
                            ux_ak_set_field_placeholder(handle, i, f.place);
                            }
                        }
                    else
                        {
                        u8* text = t.nodes[i].spec != (pointer)0 ? (u8*)t.nodes[i].spec : (u8*)"";
                        ux_ak_make_label(handle, i, ax, ay, w, hh, text);
                        }
                    ux_ak_set_control_autoresize(handle, i, mask); // set once, at creation
                    }
                else
                    {
                    // A masked control is owned by AppKit's autoresizing after placement; re-setting
                    // its frame here (from the unchanged tree) would fight it and undo the live track.
                    if (mask == (i32)0)
                        {
                        ux_ak_set_control_frame(handle, i, ax, ay, w, hh);
                        }
                    if (k == (i32)UXKindField)
                        {
                        ux_ak_update_field(handle, i);
                        }
                    if (k == (i32)UXKindLabel)
                        {
                        u8* text = t.nodes[i].spec != (pointer)0 ? (u8*)t.nodes[i].spec : (u8*)"";
                        ux_ak_set_label_text(handle, i, text);
                        }
                    }
                ux_ak_set_control_enabled(handle, i, (i32)t.nodes[i].enabled);
                ux_ak_set_control_hidden(handle, i, self.effectiveHidden(tree, i));
                }
            // apply the node's INITIAL state to a control created THIS pass —
            // relying on a second display pass to push it is timing, not design
            if (ux_ak_has_control(handle, i) != (i32)0)
                {
                if (t.nodes[i].enabled == (i16)0)
                    {
                    ux_ak_set_control_enabled(handle, i, (i32)0);
                    }
                if (t.nodes[i].hidden != (i16)0)
                    {
                    ux_ak_set_control_hidden(handle, i, (i32)1);
                    }
                // Alignment is pushed EVERY pass, not only on the first: it is
                // changed after realize (an editor's inspector does exactly
                // that), and a first-pass-only push is the bug that made
                // "Checked" go stale on GTK.
                if (k == (i32)UXKindLabel || k == (i32)UXKindField)
                    {
                    ux_ak_set_control_align(handle, i, self.alignOf(t.nodes[i].peer));
                    }
                }
            }
        // Anything realized during THIS pass was added above the shield, so put
        // it back on top.  A shield that stops working the moment the next
        // widget appears is worse than none: it works while you are testing it.
        if (ux_ak_has_shield(handle) != (i32)0)
            {
            ux_ak_raise_shield(handle);
            }
        }

    // ---- text editing (identical logic to the Win32 driver — the driver IS the edit engine) ----
    pointer fieldEditorNew(u8* buf, i32 cap)
        {
        AKField* f = (AKField*)malloc((u32)sizeof(AKField));
        f.buf = buf;
        f.cap = cap;
        f.valid = (u8*)0;
        f.place = (u8*)0;
        f.secure = (i32)0;
        return (pointer)f;
        }
    void fieldEditorSetValid(pointer ed, u8* valid)
        {
        ((AKField*)ed).valid = valid;
        }
    void fieldEditorSetPlaceholder(pointer ed, u8* s)
        {
        ((AKField*)ed).place = s;
        }
    void fieldEditorSetSecure(pointer ed, i32 on)
        {
        ((AKField*)ed).secure = on;
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
        AKField* f = (AKField*)((AKTree*)tree).nodes[obj].spec;
        if (f == (AKField*)0)
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
            if (c == (i32)0)
                {
                return (i32)1;
                }
            for (i32 i = c - (i32)1; i < len; i = i + (i32)1)
                {
                b[i] = b[i + (i32)1];
                }
            caret[0] = c - (i32)1;
            return (i32)1;
            }
        if (ch >= (i32)32 && ch < (i32)127)
            {
            if (len >= f.cap - (i32)1)
                {
                return (i32)1;
                }
            if (f.valid != (u8*)0)
                {
                i32 vn = (i32)0;
                while (f.valid[vn] != (u8)0)
                    {
                    vn = vn + (i32)1;
                    }
                if (c < vn && !self.validOk(f.valid[c], ch))
                    {
                    return (i32)1;
                    }
                }
            for (i32 i = len; i > c; i = i - (i32)1)
                {
                b[i] = b[i - (i32)1];
                }
            b[c] = (u8)ch;
            b[len + (i32)1] = (u8)0;
            caret[0] = c + (i32)1;
            return (i32)1;
            }
        return (i32)0;
        }

    // ---- menus (NSMenu, built from the neutral UXMenuDef — same walk as UXWin32Driver) ---------
    i32 menuTag(i32 titleOrd, i32 itemOrd)
        {
        return titleOrd * (i32)256 + itemOrd;
        }
    pointer menuBuild(pointer defs, i32 n, i32 screenW)
        {
        UXMenuDef* d = (UXMenuDef*)defs;
        pointer bar = ux_ak_menu_new();
        for (i32 t = (i32)0; t < n; t = t + (i32)1)
            {
            pointer sub = ux_ak_menu_add_title(bar, d[t].title);
            u8** items = d[t].items;
            for (i32 j = (i32)0; j < d[t].nitems; j = j + (i32)1)
                {
                u8* s = items[j];
                i32 tag = self.menuTag(t, j);
                // "-" : a separator
                if (s[0] == (u8)45 && s[1] == (u8)0)
                    {
                    ux_ak_menu_add_item(sub, (u8*)"", tag, (i32)0, (i32)0, (i32)1);
                    }
                else
                    {
                    i32 checked = (i32)0;
                    i32 disabled = (i32)0;
                    u8* text = s;
                    // pre-ticked
                    if (s[0] == (u8)1)
                        {
                        checked = (i32)1;
                        text = &s[1];
                        }
                    // disabled
                    else if (s[0] == (u8)2)
                        {
                        disabled = (i32)1;
                        text = &s[1];
                        }
                    ux_ak_menu_add_item(sub, text, tag, checked, disabled, (i32)0);
                    }
                }
            }
        return bar;
        }
    void menuShow(pointer menu, i32 show)
        {
        if (show != (i32)0)
            {
            ux_ak_menu_set_main(menu);
            }
        }
    // ids ARE ordinals
    i32 menuItemOrd(pointer menu, i32 titleOrd, i32 itemObj)
        {
        return itemObj;
        }
    void menuCheck(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
        {
        ux_ak_menu_check(menu, self.menuTag(titleOrd, itemOrd), on);
        }
    void menuEnable(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
        {
        ux_ak_menu_enable(menu, self.menuTag(titleOrd, itemOrd), on);
        }

    i32 alertRun(i32 icon, u8* lines, u8* buttons, i32 defaultBtn)
        {
        return ux_ak_alert(icon, lines, buttons, defaultBtn);
        }

    // The neutral run loop calls this.  INTERACTIVE: hand the whole loop to [NSApp run] — content
    // events are forwarded to the toolkit by xgAKDispatch, so this blocks until the app is stopped
    // (close box or app.stop()), then reports None (running is already false, so the loop unwinds).
    // HEADLESS: decode one synthesized event from the queue.
    void nextEvent(i32 timeoutMs, UXEvent* ev)
        {
        ev.kind = (u8)UXEventNone;
        if (ux_ak_interactive() != (i32)0)
            {
            ux_ak_run(); // blocks in [NSApp run] until stopped
            // The close box breaks [NSApp run] via ux_ak_stop but does NOT reach the neutral app, so
            // surface it as a Close here -> dispatchEvent calls app.stop() and this loop unwinds
            // (otherwise it would just re-enter [NSApp run] on a window-less app).
            if (ux_ak_quit() != (i32)0)
                {
                ev.kind = (u8)UXEventClose;
                }
            return;
            }
        i32 kind = (i32)0;
        i32 x = (i32)0;
        i32 y = (i32)0;
        i32 key = (i32)0;
        ux_ak_next_event(timeoutMs, &kind, &x, &y, &key);
        ev.kind = (u8)kind;
        ev.x = (i16)x;
        ev.y = (i16)y;
        ev.key = (u16)key;
        if (kind == (i32)UXEventMenuSelect)
            {
            ev.a = x + (i32)2;
            ev.b = y;
            }
        // x carried the handle (headless)
        if (kind == (i32)UXEventResize)
            {
            ev.handle = x;
            }
        }
    void pumpMessages(i32 timeoutMs, UXEvent* ev)
        {
        ev.kind = (u8)UXEventNone;
        }

    i32 liveNativeCount(void)
        {
        return ux_ak_native_count();
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

    // ---- AppKit-specific (not part of UXViewDriver) --------------------------
    // GUI mode: show windows and let [NSApp run] own the loop.  A test leaves this off (headless:
    // offscreen paint + synthetic events).  Call before boot.
    void setInteractive(bool on)
        {
        ux_ak_set_interactive(on ? (i32)1 : (i32)0);
        }
    // Wire native event forwarding to `app` (interactive).  Call after creating the UXApplication.
    void attachApp(UXApplication* app)
        {
        gAKApp = app;
        ux_ak_set_dispatch((pointer)&xgAKDispatch);
        ux_ak_set_control_fire((pointer)&xgAKFireControl);
        ux_ak_set_value_changed((pointer)&xgAKValueChanged); // slider/stepper/... value changes
        }
    }
