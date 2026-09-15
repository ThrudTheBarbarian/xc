//xtc-flags: expect=sema-error
// A `final` method may not satisfy a protocol requirement: a protocol call
// dispatches through a vtable slot, and `final` is precisely a request for no
// slot — so the call would have nothing to land on.

protocol Drawable { void draw(void); }

class S <Drawable> { final void draw(void) { } }   // no such thing

void main(void) { }
