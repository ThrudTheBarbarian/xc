// UXDragSession.xc — a drag-and-drop session (NSDraggingSession / NSDraggingInfo in shape).
//
// A drag carries a PASTEBOARD (the data, offered in several types) from a source, and each drop
// candidate the pointer passes over negotiates an OPERATION (copy / move / link) limited to what the
// source allows.  The negotiation and delivery are backend-neutral and testable; the mouse tracking,
// drag image and OS handoff are the driver's job — it drives this same session object.
#import "Array.xc"
#import "UXPasteboard.xc"

#define UX_DRAG_NONE 0
#define UX_DRAG_COPY 1
#define UX_DRAG_MOVE 2
#define UX_DRAG_LINK 4

// Anything that can receive a drop.  dragEntered returns the operation it WOULD perform (the session
// masks it to the allowed set); dragPerform consumes the drop and returns whether it was accepted.
protocol UXDragDestination
    {
    i32 dragEntered(UXDragSession * s);
    bool dragPerform(UXDragSession * s);
    }

class UXDragSession
    {
    Object* source;
    UXPasteboard* pasteboard;
    i32 allowedOps; // bitmask the source permits
    i32 operation;  // last negotiated op (masked)
    i16 hotX;
    i16 hotY;

    void init()
        {
        source = (Object*)0;
        pasteboard = (UXPasteboard*)0;
        allowedOps = (i32)UX_DRAG_COPY;
        operation = (i32)UX_DRAG_NONE;
        hotX = (i16)0;
        hotY = (i16)0;
        }

    static UXDragSession* begin(Object* source, UXPasteboard* pb, i32 allowedOps)
        {
        UXDragSession* s = new UXDragSession();
        s.source = source;
        s.pasteboard = pb;
        s.allowedOps = allowedOps;
        return s;
        }

    // The pointer entered a candidate: ask it, mask to the allowed set, remember the result.
    i32 enter(UXDragDestination* target)
        {
        i32 want = target.dragEntered(self);
        operation = want & allowedOps;
        return operation;
        }
    bool canDrop(void)
        {
        return operation != (i32)UX_DRAG_NONE;
        }

    // Deliver the drop if the negotiated op is non-empty; returns whether the target accepted it.
    bool deliver(UXDragDestination* target)
        {
        if (operation == (i32)UX_DRAG_NONE)
            {
            return false;
            }
        return target.dragPerform(self);
        }

    // Convenience passthroughs to the carried pasteboard.
    bool hasType(u8* type)
        {
        return pasteboard != (UXPasteboard*)0 && pasteboard.hasType(type);
        }
    u8* stringForType(u8* type)
        {
        return pasteboard == (UXPasteboard*)0 ? (u8*)0 : pasteboard.stringForType(type);
        }
    void setHotSpot(i16 x, i16 y)
        {
        hotX = x;
        hotY = y;
        }
    }
