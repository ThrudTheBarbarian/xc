// UXViewDriver.xc — the seam between the neutral toolkit and a native backend.
//
// doc/XTG-MULTIPLATFORM.md §6/§7: the generic layer owns lifetime (strong refs); a
// stateless, per-platform driver owns the native ops, structure, and the reverse map.
// UXWindow/UXView talk to the driver instead of calling wind_*/objc_* directly, so a
// second backend (Win32/AppKit/GTK) is a second implementation of THIS interface — the
// neutral layer above it does not change.
//
// It is "stateless" in the per-view sense: the native handle IS the per-object state, so
// the driver takes a handle and acts on it rather than holding view state.  The one piece
// of bookkeeping it does own is the §10 native-object counter (live natives of this
// backend), which the per-backend memory gate reads back.
//
// The neutral KIND of a view, independent of any backend.  structAppend takes one of these
// and the driver realizes it natively — GEM maps them to G_BOX/G_USERDEF/G_BUTTON/G_FTEXT/
// G_STRING; a Win32 driver would make a child window of the matching class.
//   Box    — a container the backend paints (a window/table background)
//   View   — a custom-drawn view: the app's drawRect paints it
//   Button — a native push button (label + click)
//   Field  — a native editable text field
//   Label  — native static text (a table cell)
#import "UXGraphics.xc" // beginViewDraw hands back the neutral drawing context
#import "UXEvent.xc"    // nextEvent fills a neutral UXEvent

//   Table  — a native list/table (AppKit: NSTableView); GEM/Win32 render it as a box + row subtree
//   Checkbox / Radio — a native toggle (Win32: BUTTON with BS_CHECKBOX/BS_RADIOBUTTON); GEM/AppKit
//     have no native art for these, so they fall through to the app-drawn (UXKindView) seam.
enum UXKind = {UXKindBox = 0, UXKindView = 1, UXKindButton = 2, UXKindField = 3, UXKindLabel = 4, UXKindTable = 5, UXKindCheckbox = 6, UXKindRadio = 7, UXKindScroll = 8,
    // native controls with a per-backend realization (self-drawn drawRect is the GEM/fallback):
    UXKindSlider = 9, UXKindPopup = 10, UXKindStepper = 11, UXKindProgress = 12, UXKindSegmented = 13,
    UXKindToolbar = 14, // realized as a native NSToolbar (window chrome), not a subview
    // An INPUT SHIELD: a bare native surface that covers a region and hands every press
    // to the toolkit instead of to the native controls beneath it.
    //
    // Needed because on most backends a UXView is DRAWN, not realized -- there is one
    // native view per window and the controls are flat children of it -- so a plain view
    // placed "on top" in the toolkit's own tree cannot intercept anything: the platform
    // routes a click to the NSButton/HWND/GtkWidget under the pointer and the toolkit
    // never hears about it.  A design surface (an interface builder's canvas) needs the
    // opposite: real widgets, drawn by the real backend, that a click SELECTS rather than
    // operates.  The shield is the one place that inversion lives.
    UXKindShield = 15};

// Autoresize mask (springs & struts): how a view follows its window on resize.  A backend that
// resizes natively (AppKit) applies it so the control tracks the frame LIVE during a drag, with no
// toolkit code in the resize loop; GEM/Win32 ignore it.  Default 0 = pinned top-left, fixed size.
// Combine the edges a view stays glued to with the dimensions it may stretch.
#define UX_ANCHOR_LEFT 1
#define UX_ANCHOR_RIGHT 2
#define UX_ANCHOR_TOP 4
#define UX_ANCHOR_BOTTOM 8
#define UX_FLEX_WIDTH 16
#define UX_FLEX_HEIGHT 32

// A menu, described neutrally: a title, its item strings (each marker-encoded — "-" a
// separator, \x01/\x02 a check/disable prefix), and how many.  menuBuild takes an array of
// these.  Layout matches GEM's menu_def (const char*, const char**, int) so the GEM driver
// reads the same bytes; a Win32/AppKit driver walks the same array to build its native menu.
struct UXMenuDef
    {
    u8* title;
    u8** items;
    i32 nitems;
    }

    // A field-editing step, neutral: focus the field, process one key, drop focus.  The driver
    // maps these to its edit engine (GEM: ED_INIT / ED_CHAR / ED_END).
    enum UXEdit = {UXEditBegin = 0, UXEditKey = 1, UXEditEnd = 2};

protocol UXViewDriver
    {
    // Native window lifecycle.  windowCreate mints a native window and counts it;
    // windowDestroy releases it (out of the z-order, surface freed, handle slot freed)
    // and un-counts it.  windowDestroy is only ever called with a live handle — UXWindow
    // owns the "is it still open?" question and zeroes its handle after destroy.
    i32 windowCreate(i32 x, i32 y, i32 w, i32 h);              // -> native handle (standard chrome)
    void windowSetContent(i32 handle, pointer fn, pointer ud); // draw callback + its ctx
    void windowOpen(i32 handle, i32 x, i32 y, i32 w, i32 h);
    void windowDestroy(i32 handle);

    // Window chrome the native frame renders — neutral here, GEM's WF_*/hi-lo pack lives
    // in the driver (§11: "the toolkit is where types go; the [native layer] is where
    // compatibility goes").
    void windowSetTitle(i32 handle, u8 * s);
    void windowSetSubtitle(i32 handle, u8 * s);
    void windowSetInfo(i32 handle, u8 * s);
    void windowSetIcon(i32 handle, u8 * slice);
    void windowSetModified(i32 handle, bool m);

    // Scrolling: the native frame owns the bar (draw, thumb, wheel, clamp); the toolkit
    // only reports content size and reads/sets the resulting offset.
    void windowContentSize(i32 handle, i32 w, i32 h);
    i32 windowScrollX(i32 handle);
    i32 windowScrollY(i32 handle);
    void windowSetScroll(i32 handle, i32 x, i32 y);

    // The window's CURRENT content-area size (its work area) — what the toolkit reflows into after a
    // resize.  GEM reads WF_WORKXYWH, AppKit the content view bounds, Win32 the client rect.
    void windowContentGeometry(i32 handle, i32 * w, i32 * h);

    // Repaint requests (§6 redraw): whole window, or one accumulated dirty rect.
    void windowInvalidate(i32 handle);
    void windowInvalidateRect(i32 handle, i32 x, i32 y, i32 w, i32 h);

    // Raise a window to the front of the z-order and give it focus (a Windows-menu pick, or
    // re-selecting an already-open window).  Each backend has its own primitive.
    void windowOrderFront(i32 handle);

    // A native file-open dialog.  hasNativeFileOpen() is true where the OS has one (AppKit NSOpenPanel,
    // Win32 GetOpenFileName); UXOpenPanel falls back to a toolkit-drawn panel where it is false (GEM).
    // fileOpen writes the chosen path into out (capacity outCap) and returns 1, or returns 0 if cancelled.
    bool hasNativeFileOpen(void);
    i32 fileOpen(u8 * prompt, u8 * startDir, u8 * out, i32 outCap);
    // A native colour picker (AppKit NSColorPanel, Win32 ChooseColor).  hasNativeColorPicker() is true
    // where the OS has one; the demo falls back to a toolkit-drawn wheel/sliders where it is false (GEM).
    // pickColor seeds it with r/g/b (0..255), writes the chosen colour into out*, returns 1 or 0 on cancel.
    bool hasNativeColorPicker(void);
    i32 pickColor(i32 r, i32 g, i32 b, i32 * outR, i32 * outG, i32 * outB);
    // A native font picker (AppKit NSFontPanel).  hasNativeFontPicker() is true where the OS has one; the
    // demo falls back to a toolkit-drawn chooser where it is false (GEM, Win32).  pickFont seeds it with
    // family/size/bold/italic, writes the chosen font out*, and returns 1 or 0 on cancel.
    bool hasNativeFontPicker(void);
    i32 pickFont(u8 * inFamily, i32 inSize, i32 inBold, i32 inItalic,
                 u8 * outFamily, i32 outCap, i32 * outSize, i32 * outBold, i32 * outItalic);
    // How wide `s` renders, in pixels, in the UI font at `size` (0 = the UI default).  Line breaking
    // is arithmetic until somebody can answer this: UXTextLayout assumed a uniform character width,
    // which is wrong for every font all three backends actually draw with.  GEM asks the VDI
    // (vqt_extent), Win32 GDI (GetTextExtentPoint32A), Cocoa NSString sizeWithAttributes.
    // Milliseconds since some fixed point — differences are all anyone may read from it.  The event
    // recorder stamps each captured event with it; an animation or a double-click test would too.
    i32 nowMs(void);
    // The WALL CLOCK in UTC civil components, written into out7 as
    //     [0]=year [1]=month(1..12) [2]=day [3]=hour [4]=minute [5]=second [6]=microsecond
    // Components, not an epoch count, because every backend HAS them natively (Win32 SYSTEMTIME,
    // POSIX gmtime) and epoch milliseconds do not fit an i32 anyway — nowMs() is a difference clock
    // and nothing more.  One pointer rather than seven out-params: xtc's arm64 backend mis-passes
    // arguments past the eighth.  UXDate.currentDate reads it.
    void nowUTC(i32 * out7);
    // The host's current UTC offset in MINUTES (+60 = one hour east).  DST already applied, because
    // the system owns the rules — this is the only zone answer a toolkit can give honestly without
    // shipping a tz database.  0 where the platform has no notion of local time.
    i32 localOffsetMinutes(void);

    // PERSISTENT SETTINGS: a (domain, key) -> string store that outlives the process.  Everything
    // above this line is pixels and events; this is the one seam that writes to the machine, and it
    // exists because UXKeyValueStore was a lie — an app could "save" a preference and find it gone
    // next launch.  Each backend uses what its system already keeps preferences in rather than
    // inventing a file format: XTOS the SQLite registry the desktop shares (a `settings` table),
    // macOS NSUserDefaults, Win32 the profile (.ini) API.
    //
    // `domain` namespaces a key to one application — two apps may each keep a "fontSize" — and 0 or
    // "" is the SHARED domain that applies to everybody.  These are EXACT lookups: the domain ->
    // shared fallback is UXKeyValueStore's job, so the rule is identical on every backend rather
    // than three implementations of it.  settingGet writes at most cap bytes (NUL included) and
    // returns false when there is no value; a backend with nowhere to persist returns false from
    // all three and the toolkit stays in memory.
    bool settingGet(u8 * domain, u8 * key, u8 * out, i32 cap);
    bool settingSet(u8 * domain, u8 * key, u8 * value);
    bool settingRemove(u8 * domain, u8 * key);

    i32 textWidth(u8 * s, i32 size);
    // The same, for STYLED text: bold is wider than regular, so attributed text cannot be wrapped
    // with the plain measure without overflowing its column.  The measuring counterpart of
    // drawTextFont, and it must agree with it or the wrap will not match the drawing.
    i32 textWidthStyled(u8 * s, u8 * family, i32 size, bool bold, bool italic);

    // Run a popup button's menu, for a backend whose popup is NOT a native control.  `peer` is the
    // UXPopUpButton (it answers nativeItemCount/nativeItemTitle); x,y are window-local, the button's
    // bottom-left.  Returns the chosen item index, or -1 for cancelled — and -1 is also what a backend
    // returns when the OS control pops itself (AppKit/Win32), which report through applyNativeSelection.
    i32 runPopupMenu(pointer peer, i32 x, i32 y);
    // The families the toolkit chooser lists (where there is no native panel): GEM enumerates its loaded
    // faces, Win32/Cocoa return a curated set.  fontFamilyName writes name idx into out, returns its length
    // (or -1).  The name that comes back is what drawTextFont is later handed to select the face.
    i32 fontFamilyCount(void);
    i32 fontFamilyName(i32 idx, u8 * out, i32 cap);
    // List a directory into out as "t name\n" lines (t='d'/'f'); returns the count or -1.  Only the
    // toolkit-drawn panel (GEM) needs it; the native-panel backends stub it (they read the FS themselves).
    i32 listDir(u8 * path, u8 * out, i32 outCap);
    // File operations for the toolkit panel's Delete / Rename / Move / Copy (1 = ok, 0 = fail).
    i32 fileDelete(u8 * path);
    i32 fileRename(u8 * src, u8 * dst);
    i32 fileCopy(u8 * src, u8 * dst);

    // Structural queries on the native tree (§6: the driver owns structure + the reverse
    // map, so hit-test and absolute-coords are driver ops — the neutral layer never walks
    // a realization tree).  `tree` is the backend's structure handle (GEM: the OBJECT[]).
    void treeOffset(pointer tree, i32 obj, i32 * ax, i32 * ay);                 // absolute coords of obj
    i32 treeHitTest(pointer tree, i32 start, i32 x, i32 y);                     // deepest hit, or -1
    void structAbsFrame(pointer h, i32 i, i32 * x, i32 * y, i32 * w, i32 * ht); // absolute frame

    // The realization tree itself is the driver's (§6).  The generic layer holds it as an
    // opaque handle and calls these to build/mutate it — never naming the backend structure.
    pointer structNew(void); // -> opaque tree handle
    void structFree(pointer h);
    void structAdopt(pointer h, pointer t, i32 n); // adopt an external tree (.rsc)
    pointer structObjects(pointer h);              // the raw structure, for the draw seam
    i32 structLength(pointer h);
    i32 structAppend(pointer h, i32 kind, i32 x, i32 y, i32 w, i32 ht); // -> new index
    void structAddChild(pointer h, i32 parent, i32 child);
    void structRemoveChild(pointer h, i32 parent, i32 child);
    void structFinalise(pointer h);

    // Per-object geometry + state — neutral view properties (frame, hidden, enabled,
    // selected, clips-children); the backend stores them however it likes.
    void structSetFrame(pointer h, i32 i, i32 x, i32 y, i32 w, i32 ht);
    void structFrame(pointer h, i32 i, i32 * x, i32 * y, i32 * w, i32 * ht);
    void structSetHidden(pointer h, i32 i, i32 on);
    i32 structIsHidden(pointer h, i32 i);
    void structSetEnabled(pointer h, i32 i, i32 on);
    i32 structIsEnabled(pointer h, i32 i);
    void structSetSelected(pointer h, i32 i, i32 on);
    i32 structIsSelected(pointer h, i32 i);
    void structSetClips(pointer h, i32 i, i32 on);

    // Control realization: an object's content descriptor + its selectable/editable kind.
    void structSetSpec(pointer h, i32 i, pointer spec);
    void structSetSelectable(pointer h, i32 i, i32 on);
    void structSetEditable(pointer h, i32 i, i32 on);

    // Attach a neutral peer object (the owning UXView) to a node, for backends that overlay a
    // native widget driven by that object — an AppKit NSTableView reads its rows/columns straight
    // from the UXTableView.  GEM/Win32 render from the object subtree and ignore this (no-op).
    void structSetPeer(pointer h, i32 i, pointer peer);

    // Springs & struts for a node (UX_ANCHOR_* | UX_FLEX_*).  A native-resize backend applies it so
    // the control tracks the window live; GEM/Win32 render fixed layouts and ignore it (no-op).
    void structSetAutoresize(pointer h, i32 i, i32 mask);

    // True if the backend repositions masked views itself on resize (AppKit's NSView autoresizing).
    // When false, the neutral layer runs the springs & struts solve (UXView.resizeSubviews) on resize.
    bool driverAutoresizes(void);

    // Painting the tree: register the per-custom-view draw callback (fn carries its own ctx),
    // then walk the tree, which invokes fn for each custom view within the clip.  graphicsHandle
    // is the backend drawing context the callback binds a graphics object to.
    void treeSetUserDraw(pointer fn, pointer ud);
    void treeDraw(pointer tree, i32 start, i32 clx, i32 cly, i32 clw, i32 clh);
    UXGraphics* beginViewDraw(i32 ax, i32 ay, i32 aw, i32 ah);
    // Subtracted from every beginViewDraw origin: lets a subtree be drawn into a native sub-surface
    // (a scroll view's document view) at that surface's own 0,0.  0,0 for the normal window draw.
    void setDrawOffset(i32 x, i32 y);
    // True when a scroll view maps to a native scroll container that OWNS the offset (AppKit/win32),
    // so UXScrollView leaves its document at 0 instead of moving it itself (GEM: false, moves it).
    bool scrollsNatively(void);
    // Drive that native container: move it `px` from the top, and read back where it sits.  Without
    // these, scrollsNatively() meant the toolkit could not scroll a view AT ALL on Win32/AppKit —
    // UXScrollView.scrollTo returned early because the native container owns the offset, and nothing
    // could then tell that container to move.  Programmatic scrolling (reveal a row, restore a
    // position, replay a recorded scroll) was silently a no-op on two of three backends.
    // The node is the UXScrollView's own index in `h`.  A backend that does not scroll natively
    // implements these as a no-op / 0 — there the toolkit's own offset is the truth.
    void nativeScrollTo(pointer h, i32 node, i32 px);
    i32 nativeScrollPx(pointer h, i32 node);

    // Reconcile any NATIVE control widgets with the tree (§ native-overlay).  GEM/Win32 draw their
    // controls, so this is a no-op there; an AppKit driver creates/positions real NSButton/
    // NSTextField subviews here (called from UXWindow.displayAll, outside the draw).
    void realizeTree(i32 handle, pointer tree);

    // A field editor bound to the app's text buffer (GEM: a TEDINFO), set as the field's
    // content; setValid installs a per-character validation string; free releases it.
    pointer fieldEditorNew(u8 * buf, i32 cap);
    void fieldEditorSetValid(pointer ed, u8 * valid);
    // A grey prompt shown while the field is empty (NSTextField placeholderString / EM_SETCUEBANNER).
    // The GEM AES G_FTEXT has no cue-banner concept, so its driver implements this as a no-op.
    void fieldEditorSetPlaceholder(pointer ed, u8 * s);
    // Mask input as a password (NSSecureTextField / ES_PASSWORD).  GEM's AES field editor has no
    // password mode, so its driver implements this as a no-op (the field shows plain text).
    void fieldEditorSetSecure(pointer ed, i32 on);
    void fieldEditorFree(pointer ed);

    // Native text editing (§5): the backend's edit engine operates the field in place —
    // insert, delete, caret, per-character validation.  mode is ED_INIT / ED_CHAR / ED_END;
    // caret is carried in and out; returns nonzero if the key was consumed.
    i32 editText(pointer tree, i32 obj, i32 key, i32 * caret, i32 mode);

    // Menus (§5): a separate subsystem — a neutral model realized by a small vocabulary.
    // menuBuild turns the packed menu defs into the backend's menu object; the rest operate
    // it (show the bar, map an item object to its ordinal, check/enable an item).
    pointer menuBuild(pointer defs, i32 n, i32 screenW);
    void menuShow(pointer menu, i32 show);
    i32 menuItemOrd(pointer menu, i32 titleOrd, i32 itemObj);
    void menuCheck(pointer menu, i32 titleOrd, i32 itemOrd, i32 on);
    void menuEnable(pointer menu, i32 titleOrd, i32 itemOrd, i32 on);

    // A modal alert: icon (0 none / 1 note / 2 wait / 3 stop), pipe-joined lines and buttons
    // ("Yes|No"), and the 1-based default button.  Blocks, returns the 1-based button pressed.
    // GEM builds form_alert's string and runs its modal loop; a host backend pops a native
    // dialog (Win32 MessageBox, AppKit NSAlert) and maps the answer back to the neutral index.
    i32 alertRun(i32 icon, u8 * lines, u8 * buttons, i32 defaultBtn);

    // Event source (§5 run loop): block up to timeoutMs and fill ev with the next event,
    // decoded to a neutral UXEvent (mouse / key / menu-select / close / resize / move / none).
    // pumpMessages drains pending window messages without consuming input.  A host backend
    // pumps its own native queue here.
    void nextEvent(i32 timeoutMs, UXEvent * ev);
    void pumpMessages(i32 timeoutMs, UXEvent * ev);
    // Which native window is at a screen point (0 = none) — for routing a click.
    i32 windowAtPoint(i32 x, i32 y);

    // One step of a modal drag-track: block until the pointer moves or the button releases.  Fills
    // window-local x,y; returns 1 while dragging, 0 once released.  A table calls this in a loop after a
    // press to drag-select rows.  Backends whose native controls own drag (win32/AppKit tables) return 0.
    i32 trackDragStep(i32 * x, i32 * y);

    // Bring the backend up (GEM: framebuffer + VDI + theme + AES); fills the screen size.
    // themePointer is the backend theme the draw seam binds against.
    bool boot(i32 * screenW, i32 * screenH);

    // The §10 gate reads this: live native objects of this backend.  A create/destroy
    // loop must return it to its baseline.
    i32 liveNativeCount(void);

    // True where the PLATFORM owns the main thread's run loop (iOS): run() then
    // calls runLoop() — which never returns — instead of the blocking
    // nextEvent shape, and the delegate's start moment fires from the driver's
    // native callback.  The one sanctioned loop inversion (the spiked B+A
    // decision); the desktop and web backends all answer false and runLoop()
    // is a no-op there.
    bool driverOwnsRunLoop(void);
    void runLoop(void);

    // Which form-factor class this backend presents (UXNB-V2.md §1) — the input to
    // nib variant selection.  An open registry, not a trio: desktop for all four
    // current backends (the web driver may later answer from viewport/pointer
    // heuristics; a constant is correct today), phone/tablet with the mobile
    // backends.  Selection walks the §1 fallback chain, so a nib with only a
    // desktop layout still runs everywhere.
    i32 formFactorClass(void);
    }

// The form-factor registry (UXNB-V2.md §1).  Values are the on-disk variant-class
// words, so they are ABI: allocate here, never renumber.
#define UX_FORM_ANY 0
#define UX_FORM_DESKTOP 1
#define UX_FORM_TABLET 2
#define UX_FORM_PHONE 3

// The one driver for this process, chosen at boot (UXApplication.boot).  A global, like
// gGraphics/gTheme — the neutral layer reaches it without threading it through every call.
// GEM is the only backend today, so there is exactly one; a host build sets its own here.
UXViewDriver* gDriver;
