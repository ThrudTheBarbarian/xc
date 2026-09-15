// designable_no_protocol.xc — uxkit/026, the refusal half.
//
// `outlet` and `:action` are not decorations: they make the compiler write
// setOutlet/wireAction bodies and conform the class to the binding protocol.
// A protocol the class cannot see cannot be conformed to, and the loader
// resolves against the framework's itable slots — so a designable class in a
// module that never imported the UI framework is a mistake to say out loud,
// not one to synthesise around.
//
// It is worth a diagnostic rather than silence because the failure otherwise
// arrives at LOAD, in the loader, one process and one nib away from the file
// that is actually wrong.
//xtc-flags: expect=sema-error

class Panel : Object
{
    outlet Object* title;        // no UXDesignable in scope — refuse
    void init(void) { }
}

void main(void)
{
    Panel* p = new Panel();
}
