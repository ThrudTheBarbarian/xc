// vtable_stack_args.xc — uxkit/033.
//
// System V passes integer/pointer arguments past r9 on the STACK. The x86_64
// back end's INDIRECT (vtable) call marshalled only what fitted in registers:
// every argument from the 7th on — the receiver counts as one — was dropped,
// along with the `sub rsp` that reserves room for them, so the callee read
// whatever its caller's frame happened to leave there and wrote through it.
//
// Why it survived a 480-fixture corpus: a CLASS-typed call devirtualises to a
// direct call, and the direct path has always been correct; at -O2 and above
// the inliner deletes the call outright. It takes a PROTOCOL receiver, seven
// arguments, and a dispatch the optimiser cannot see through. UXViewDriver's
// `absFrame(h, i, x, y, w, ht)` is exactly seven with self, which is why the
// GTK backend died in its first draw and nothing here did.
//
// The last out-param is the one that matters: it is the first stack-passed
// argument, so T4 is the assertion that was failing. The three before it are
// register-passed and always worked — they are here to prove the fix did not
// move anything that already arrived.
//
//   T1..T3  the register-passed out-params still arrive
//   T4      the STACK-passed 7th argument arrives
//   T5..T8  the same call with the receiver typed as the CLASS (direct path)
#import "Stdio.xc"
#import "Assert.xc"

protocol Framer {
    void absFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht);
}

class Frame : Object <Framer>
{
    void init(void) { }
    void absFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
    {
        x[0]  = (i32)11;
        y[0]  = (i32)22;
        w[0]  = (i32)33;
        ht[0] = (i32)44;        // the 7th argument, on the stack
    }
}

void main(void)
{
    Assert.reset();

    i32 ax = (i32)0; i32 ay = (i32)0; i32 aw = (i32)0; i32 ah = (i32)0;

    Frame* c = new Frame();
    Framer* f = (Framer*)c;
    f.absFrame((pointer)0, (i32)5, &ax, &ay, &aw, &ah);

    Assert.isEqual((u32)ax, (u32)11);        // T1
    Assert.isEqual((u32)ay, (u32)22);        // T2
    Assert.isEqual((u32)aw, (u32)33);        // T3
    Assert.isEqual((u32)ah, (u32)44);        // T4 — the stack-passed one

    ax = (i32)0; ay = (i32)0; aw = (i32)0; ah = (i32)0;
    c.absFrame((pointer)0, (i32)5, &ax, &ay, &aw, &ah);
    Assert.isEqual((u32)ax, (u32)11);        // T5
    Assert.isEqual((u32)ay, (u32)22);        // T6
    Assert.isEqual((u32)aw, (u32)33);        // T7
    Assert.isEqual((u32)ah, (u32)44);        // T8

    Assert.summary();
}
