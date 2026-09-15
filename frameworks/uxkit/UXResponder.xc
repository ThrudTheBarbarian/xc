// UXResponder.xc — the responder chain.
//
// AppKit walks the chain by asking `respondsToSelector:`.  xtc has no reflection,
// no selectors and no message forwarding — and it does not need them.  Instead the
// base class's handlers FORWARD to the next responder, and a subclass consumes an
// event simply by overriding and not calling super.
//
// That is better defined than AppKit's version: the chain is explicit and the
// compiler checks it, rather than it being probed at run time.
//
//     view -> superview -> ... -> contentView -> window -> application
//
// NOTE on `self.`: every call to a method that a subclass may override is written
// `self.method()`, never bare `method()`.  A bare self-call is currently
// devirtualised by xtc (see spikes/XTC-BUGS.md, bug B) and would silently run the
// BASE implementation — which for a responder chain means events vanishing.  The
// discipline stays correct once the compiler fix lands.

#import "UXEvent.xc"

class UXResponder
    {
    weak : UXResponder* nextResponder; // weak: a responder never owns the next one

    void init(void)
        {
        nextResponder = (UXResponder*)0;
        }

    void setNextResponder(UXResponder* r)
        {
        nextResponder = r;
        }

    // ---- default handlers: "not mine — pass it on" -------------------------
    // Override to consume.  Call super to consume AND keep passing it up.

    void mouseDown(UXEvent* e)
        {
        if (nextResponder != (UXResponder*)0)
            {
            nextResponder.mouseDown(e);
            }
        }
    void mouseUp(UXEvent* e)
        {
        if (nextResponder != (UXResponder*)0)
            {
            nextResponder.mouseUp(e);
            }
        }
    void mouseDragged(UXEvent* e)
        {
        if (nextResponder != (UXResponder*)0)
            {
            nextResponder.mouseDragged(e);
            }
        }
    // The wheel climbs to the first responder that scrolls — a row/cell passes it up to its table.
    void scrollWheel(UXEvent* e)
        {
        if (nextResponder != (UXResponder*)0)
            {
            nextResponder.scrollWheel(e);
            }
        }
    // ---- first responder ---------------------------------------------------
    // Can I take the keyboard?  A view says yes by overriding this (UXTextField does).
    bool acceptsFirstResponder(void)
        {
        return false;
        }

    // Told that I now have / no longer have the keyboard.  Returning false REFUSES —
    // which is how a text field with invalid contents can decline to give up focus.
    bool becomeFirstResponder(void)
        {
        return true;
        }
    bool resignFirstResponder(void)
        {
        return true;
        }

    void keyDown(UXEvent* e)
        {
        if (nextResponder != (UXResponder*)0)
            {
            nextResponder.keyDown(e);
            }
        }
    }
