//xtc-flags: expect=sema-error
// Overriding a `final` method must be rejected. Without this, `final` would be
// an unsound promise — a way to silently devirtualise a method that IS
// overridden, so the base's implementation would be hard-called and the
// override never reached (exactly bug B, reintroduced by hand).

class A { final u16 f(void) { return (u16)1; } }
class B : A { u16 f(void) { return (u16)2; } }   // no such thing

void main(void) { }
