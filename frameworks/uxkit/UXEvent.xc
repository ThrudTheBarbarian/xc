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
    // The wheel over a view (x,y = point, handle = window).  b = the DOM's deltaY in PIXELS --
    // positive scrolls DOWN, a line-wheel click is 100 -- the same number a browser hands a page, so
    // web code ports unchanged.  a = whole notches, positive scrolls UP (GEM's sense), for readers
    // that step by lines.  Every backend reports both in this sense whatever its native sign.
    UXEventWheel = 11,
    // A scroll view came to rest at a new offset (a = its node index, b = the offset).  NOT input:
    // it is the OUTCOME of input, announced because the input itself is unrecordable — dragging a
    // scrollbar happens inside the driver's modal trackDragStep, which emits no events at all, so a
    // recording would otherwise replay every click faithfully and leave the view scrolled elsewhere.
    UXEventScrolled = 12,
    // A table's selection came to rest (a = its node index, b = the anchor row, data = an IndexSet
    // of every selected row).  Like the scroll
    // above, an OUTCOME rather than input: on a backend whose table is a native list the click never
    // reaches the toolkit at all — it arrives as WM_NOTIFY/LVN_ITEMCHANGED — so this is the only
    // trace a recorder can keep of it.
    UXEventSelected = 13,
    // A native text field's contents changed (a = its node index, data = a String).  Keystrokes
    // go straight to the native EDIT/NSTextField and surface only as "the text changed", never as
    // keys — so this is the only trace a recorder can keep of typing on those backends.
    UXEventTextChanged = 14,
    // Pointer movement with NO button down (x,y = point, handle = window).  The toolkit hit-tests
    // it and hands it to the view under the pointer, the way it does a click; hover needs it.
    UXEventMouseMoved = 15,
    // The secondary (right) button (x,y = point, handle = window).  Its own kind and not mouseDown
    // with a flag: a view that opens a context menu and a view that selects must tell them apart.
    UXEventRightMouseDown = 16,
    // A key released (key as for UXEventKeyDown).  A view that holds a key down to do something
    // (a modifier-free pan, a game) needs to hear the release.
    UXEventKeyUp = 17,
    // The middle button, or any button past the second (x,y = point, handle = window, buttons =
    // UX_BUTTON_MIDDLE).  Like the right button it has its own kind: a 3-D view orbits on it.
    UXEventOtherMouseDown = 18};

// The button a press came from, in ev.buttons.
#define UX_BUTTON_LEFT $01
#define UX_BUTTON_RIGHT $02
#define UX_BUTTON_MIDDLE $04

// A key is GEM's (scancode << 8) | ascii on every backend: the low byte is the character, the high
// byte the key for those that have no character.  Every driver maps its platform's keys to these.
#define UX_KEY_ASCII $00FF
#define UX_KEY_SCAN $FF00
#define UX_KEY_TAB $09
#define UX_KEY_RETURN $0D
#define UX_KEY_ESCAPE $011B
#define UX_KEY_BACKSPACE $0E08
#define UX_KEY_DELETE $537F
#define UX_KEY_UP $4800
#define UX_KEY_DOWN $5000
#define UX_KEY_LEFT $4B00
#define UX_KEY_RIGHT $4D00
#define UX_KEY_HOME $4700
#define UX_KEY_END $4F00
#define UX_KEY_PAGEUP $4900
#define UX_KEY_PAGEDOWN $5100
// The modifier keys held at the event, in ev.modifiers, on every backend for presses, drags, the
// wheel and keys.  The first four are GEM's kstate (right-shift | left-shift | ctrl | alt); Command
// (Apple's) is the toolkit's own.  On macOS a Control-click arrives as the right button.
#define UX_MOD_SHIFT $03
#define UX_MOD_CTRL $04
#define UX_MOD_ALT $08
#define UX_MOD_CMD $10

// The platform's command key: Command on Apple's platforms, Control elsewhere.  A menu shortcut is
// matched on it, and a click with it held adds an item to a selection or takes it away.  The driver
// sets it at boot.
u16 gUXCommandModifier = (u16)UX_MOD_CTRL;

// The modifier keys held at the latest event the driver decoded, so a drag followed by trackMouse
// carries them on each step (a shift-drag that pans).  The drivers keep it current.
u16 gUXModifiers;

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
// in a/b.  The payload is whatever the kind documents: an IndexSet for a selection (which is what
// IndexSet is FOR — "exactly what a table's multi-selection wants"), a String for text.  The
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
    Object* data; // optional payload: IndexSet for a selection, String for field text

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
