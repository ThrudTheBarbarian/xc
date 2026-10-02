// UXTouch.xc — touches on a touch backend's drawn content, as UXKit's mouse events.
//
// iOS and Android draw a window's UXKit content into one platform view (a UXDrawView); native
// widgets on top take their own touches.  Everything DRAWN -- tables, custom views, an editor's
// canvas -- receives its touches here: a finger down is a mouseDown at that point (hit-tested, and
// it takes the keyboard if it wants it, exactly like a click), a finger moving is mouseDragged and
// a finger lifting is mouseUp, both to the view that took the press (UXWindow's grab).  Then the
// display pass every native event ends with.
//
// Drags arrive as EVENTS here, so a view that tracks a drag must not loop on trackDragStep on these
// backends (it returns 0 at once, and the loop would end before the finger moved); it asks
// gDriver.dragTrackingIsModal() and, when that is false, continues its drag from mouseDragged /
// mouseUp instead.
#import "UXWindow.xc"
#import "UXApplication.xc"
#import "UXEvent.xc"

#define UX_TOUCH_DOWN 0
#define UX_TOUCH_MOVE 1
#define UX_TOUCH_UP 2
#define UX_TOUCH_CANCEL 3

UXEvent* gTouchEvent;

// From the shim: `ud` is the UXWindow the content callback was registered with; x/y are in its
// content's coordinates (neutral units).
void uxTouch(pointer ud, i32 phase, i32 x, i32 y)
    {
    UXWindow* w = (UXWindow* ?)(Object*)ud;
    if (w == (UXWindow*)0)
        {
        return;
        }
    if (gTouchEvent == (UXEvent*)0)
        {
        gTouchEvent = new UXEvent();
        }
    UXEvent* e = gTouchEvent;
    e.x = (i16)x;
    e.y = (i16)y;
    e.handle = w.handle;
    e.buttons = (u16)1;
    if (phase == (i32)UX_TOUCH_DOWN)
        {
        e.kind = (u8)UXEventMouseDown;
        w.dispatchMouse(e);
        }
    else if (phase == (i32)UX_TOUCH_MOVE)
        {
        e.kind = (u8)UXEventMouseDragged;
        w.dispatchMouseDragged(e);
        }
    else
        {
        // a cancelled touch (the system took it: a gesture, an alert) still releases the view
        e.kind = (u8)UXEventMouseUp;
        e.buttons = (u16)0;
        w.dispatchMouseUp(e);
        }
    if (gApp != (UXApplication*)0)
        {
        gApp.displayIfNeeded();
        }
    }
