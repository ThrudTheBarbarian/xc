// int64_return_dispatch.xc — a 64-bit RETURN value through each call path.
//
// Found by the differential fuzzer (tests/fuzz), where it was the whole m68k
// divergence class and part of the xt6502 one. An i64 return survives a plain
// function and a direct method call, but loses its LOW word through an INDIRECT
// call — m68k returned zero for it, xt6502 returned garbage, and both got the
// HIGH word right, which is the signature of a return path that moves one word
// where it should move two.
//
// The four paths are printed side by side deliberately: they all return the
// same constant, so any line that differs from the others localises the bug to
// a dispatch kind rather than to 64-bit arithmetic. `viaFunction` and
// `viaDirect` are the controls — if THEY break, the fault is in the 64-bit
// return ABI generally, not in dispatch.
#import "Stdio.xc"

protocol P { i64 viaProto(void); }

class Base {
    i64 viaVirtual(void) { return (i64)1267207731222980658; }
}

// Overriding viaVirtual is what makes it a real vtable dispatch: an
// un-overridden method is called directly, and would not exercise the bug.
class Impl : Base <P> {
    i64 viaProto(void)   { return (i64)1267207731222980658; }
    i64 viaVirtual(void) { return (i64)1267207731222980658; }
    i64 viaDirect(void)  { return (i64)1267207731222980658; }
}

i64 viaFunction(void) { return (i64)1267207731222980658; }

void show(string tag, i64 v)
{
    Stdio.printf("%s %lu %lu\n", tag, (u32)((u64)v >> (u64)32), (u32)v);
}

void main(void)
{
    Impl@ o = new Impl();
    P@    p = o;        // protocol-typed: dispatch through the itable slot
    Base@ b = o;        // base-typed: dispatch through the vtable slot

    show("fn    ", viaFunction());      // expect 295044791 3022825522
    show("direct", o.viaDirect());      // expect 295044791 3022825522
    show("virt  ", b.viaVirtual());     // expect 295044791 3022825522
    show("proto ", p.viaProto());       // expect 295044791 3022825522
    return;
}
