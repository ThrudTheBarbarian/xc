// UXEvent.xc — one UI event, neutral.  The driver's nextEvent decodes the backend's native
// event (GEM message / mouse / key) into one of these, so the run loop names no backend code.
enum UXEventKind = {
    UXEventNone = 0, UXEventMouseDown = 1, UXEventMouseUp = 2,
    UXEventMouseDragged = 3, UXEventKeyDown = 4, UXEventRedraw = 5, UXEventQuit = 6,
    // window-system events, decoded by the driver from the native message queue:
    UXEventMenuSelect = 7, // a menu item was chosen (a = title object, b = item object)
    UXEventClose = 8,      // the close box (handle = window)
    UXEventResize = 9,     // window resized (handle = window)
    UXEventMove = 10,      // window moved   (handle = window)
    UXEventWheel = 11,     // mouse wheel over a client-drawn scroll region (x,y = point, a = notches)
    // A scroll view came to rest at a new offset (a = its node index, b = the offset).  NOT input:
    // it is the OUTCOME of input, announced because the input itself is unrecordable — dragging a
    // scrollbar happens inside the driver's modal trackDragStep, which emits no events at all, so a
    // recording would otherwise replay every click faithfully and leave the view scrolled elsewhere.
    UXEventScrolled = 12,
    // A table's selection came to rest (a = its node index, b = the anchor row, data = an UXIndexSet
    // of every selected row).  Like the scroll
    // above, an OUTCOME rather than input: on a backend whose table is a native list the click never
    // reaches the toolkit at all — it arrives as WM_NOTIFY/LVN_ITEMCHANGED — so this is the only
    // trace a recorder can keep of it.
    UXEventSelected = 13,
    // A native text field's contents changed (a = its node index, data = a String).  Keystrokes
    // go straight to the native EDIT/NSTextField and surface only as "the text changed", never as
    // keys — so this is the only trace a recorder can keep of typing on those backends.
    UXEventTextChanged = 14};

// GEM hands us key = (scancode << 8) | ascii, so mask the low byte for the character.
#define UX_KEY_ASCII $00FF
#define UX_KEY_TAB $09
#define UX_KEY_RETURN $0D
// evnt_multi's kstate, in ev.modifiers: right-shift | left-shift | ctrl | alt.
#define UX_MOD_SHIFT $03
#define UX_MOD_CTRL $04

// A tee on the event stream, set by UXApplication.setEventTap.  It lives HERE, not on the
// application, because the backends whose controls are NATIVE (Win32 BN_CLICKED, AppKit's action
// shim) turn a notification straight into ctl.mouseDown without ever passing through the app's
// dispatch — so a tap that only watched dispatchEvent saw everything on GEM and nothing on the
// other two.  A driver announces such a click here, at its coordinates, so it can be recorded and
// so replaying it hits the same control through the ordinary hit test.
callback gEventTap void(UXEvent* e);

// True while a recording is being replayed.  A DRAG is not in the event stream: pressing a scrollbar
// or a split divider enters the driver's modal trackDragStep, which follows the pointer until it is
// released — so a recorder captures the press and never sees the drag or the release.  Replaying that
// press would re-enter the modal loop, which then tracks the LIVE mouse: the widget carries on
// scrolling under the user's hand long after the replay.  While this is up, trackDragStep reports
// "not dragging" at once, so a replayed press does the press and nothing more.
bool gInputReplay;

// Some events carry more than two integers.  A table's selection is a SET of rows (an anchor alone
// replays as one row, however many were chosen) and a field's contents are a string — neither fits
// in a/b.  The payload is whatever the kind documents: an UXIndexSet for a selection (which is what
// UXIndexSet is FOR — "exactly what a table's multi-selection wants"), a String for text.  The
// recorder copies the reference, so a captured event keeps its data.
class UXEvent
    {
    u8 kind;
    i16 x;
    i16 y;
    u16 buttons;
    u16 key;
    u16 modifiers;
    i32 handle;   // the window a system event refers to
    i32 a;        // decoded payload (menu title object)
    i32 b;        // decoded payload (menu item object)
    Object* data; // optional payload: UXIndexSet for a selection, String for field text

    void init(void)
        {
        data = (Object*)0;
        kind = (u8)UXEventNone;
        x = (i16)0;
        y = (i16)0;
        buttons = (u16)0;
        key = (u16)0;
        modifiers = (u16)0;
        handle = (i32)0;
        a = (i32)0;
        b = (i32)0;
        }
    }
