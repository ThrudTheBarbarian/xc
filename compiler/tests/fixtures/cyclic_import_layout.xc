// cyclic_import_layout.xc — a cyclic #import must not corrupt field offsets
// (task #20). CycA and CycB #import each other; the include guard breaks
// the cycle by making whichever file is entered FIRST wait, so the merged
// unit holds CycB (the USER of CycA's fields) before CycA itself. The
// lowering used to map the not-yet-scanned CycA* to Ptr(Void) — silently —
// and at -O2+ the leaf inliner spliced tag()/mag() into readA with a
// layout-less FieldAddr base: every offset folded to 0, so readA returned
// bytes of the vtable slot instead of the ivars. Sentinels are $DE-style
// on purpose; zeros would pass by accident.
#import "cyclic_import_a.xc"
#import "Stdio.xc"

i32 main(void)
{
    CycA* a = new CycA();
    a.init();
    CycB* b = new CycB();
    b.init();

    Stdio.printf("%ld %ld %ld\n", b.readA(a), b.mix(), a.viaB(b));

    return 0;
}
