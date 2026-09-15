// arc_getter_vararg_leak.xc — a +1 temp consumed by a VARIADIC argument.
//
// A getter returning a strong ivar returns it retained (+1), so the caller owes
// a release. `emitStore` used to consume the pending owned temp for EVERY
// store, on the reasoning that a store into a non-owning slot "only leaks,
// which is the safe side" — and the vararg marshalling area __xtc_va_buf is
// exactly such a slot. So `printf("%@", obj.child())` dropped the release every
// time (bug 037): silent, no crash, no wrong value, just a heap that never
// comes back.
//
// The three shapes differ ONLY in how the getter's result is consumed. All
// three must dealloc both objects; the missing line is the whole test, so an
// empty .expected.out would prove nothing.
#import "Foundation.xc"
#import "Stdio.xc"

class N : Object
{
    String* _n;
    N*      _next;                 // strong: the getter returns it retained
    void init(void) { _n = 0; _next = 0; }
    static N* named(string s) { N* x = new N(); x._n = String.withCString(s); return x; }
    void link(N* o) { _next = o; }
    N*   next(void) { return _next; }
    String* description(void) { return _n; }
    // Prints the NAME, not `%@ self`: passing self to a variadic call from
    // inside dealloc recurses forever on xt6502 (bug 038), which is a
    // different fault and would mask this one.
    void dealloc(void) { Stdio.printf("  dealloc %s\n", _n.cString()); }
}

void takesOne(N* p) { }

i32 main(void)
{
    Stdio.print("bare:\n");
    { N* a = N.named("A1"); N* b = N.named("A2"); a.link(b); a.next(); }
    Stdio.print("call arg:\n");
    { N* a = N.named("B1"); N* b = N.named("B2"); a.link(b); takesOne(a.next()); }
    Stdio.print("vararg:\n");
    { N* a = N.named("C1"); N* b = N.named("C2"); a.link(b);
      Stdio.printf("  saw %@\n", a.next()); }
    Stdio.print("done\n");
    return 0;
}
