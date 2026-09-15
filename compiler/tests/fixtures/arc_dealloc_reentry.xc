// arc_dealloc_reentry.xc — retaining an object while it is being destroyed.
//
// Inside dealloc the refcount has already reached 0. Any strong binding of the
// object there — `Object* o = self;`, or the argument printf binds for `%@` —
// retains and then releases it, and the release took it back to 0 and
// dispatched dealloc AGAIN, forever (bug 038). It showed only on xt6502
// because the native back ends elide the redundant pair.
//
// `_obj_decref` had always guarded a zero count ("don't wrap, don't
// double-free"); `_obj_retain` did not, so the pair was asymmetric. A live
// object holds at least one reference, so a count of 0 can only mean "already
// dying", and retain is now a no-op on it too.
//
// Each dealloc must print enter/leave exactly ONCE.
#import "Foundation.xc"
#import "Stdio.xc"

class N : Object
{
    String* _n;
    u8      _mode;
    void init(void) { _n = 0; _mode = (u8)0; }
    static N* mk(string s, u8 m)
    {
        N* x = new N();
        x._n = String.withCString(s);
        x._mode = m;
        return x;
    }
    String* description(void) { return _n; }
    void dealloc(void)
    {
        Stdio.printf("  enter %s\n", _n.cString());
        if (_mode == (u8)1) { Object* o = self; }              // strong local
        if (_mode == (u8)2) { Stdio.printf("  %@\n", self); }  // self via %@
        if (_mode == (u8)3) { Object* o = self; Stdio.printf("  %@\n", o); }
        Stdio.printf("  leave %s\n", _n.cString());
    }
}

i32 main(void)
{
    { N* a = N.mk("plain",  (u8)0); }
    { N* b = N.mk("local",  (u8)1); }
    { N* c = N.mk("pct-at", (u8)2); }
    { N* d = N.mk("both",   (u8)3); }
    Stdio.print("done\n");
    return 0;
}
