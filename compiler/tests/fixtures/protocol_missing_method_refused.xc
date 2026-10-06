//xtc-flags: expect=sema-error
// A class that lists a protocol must implement every method the protocol does
// not mark `optional`. Here `valueOf` is misnamed `valueFor`, so the slot the
// protocol call goes through would be empty: a compile error naming the class,
// the protocol and the method, not a call through null at run time (bug 622).
#import "Stdio.xc"
protocol Source
    {
    i32 valueOf(i32 i);
    optional void touched(i32 i);
    }
class Src : Object<Source>
    {
    i32 valueFor(i32 i) { return i * 2; }
    }
i32 main(void)
    {
    Src* s = new Src();
    Source* p = (Source*)s;
    Stdio.printf("%d\n", p.valueOf(21));
    return 0;
    }
