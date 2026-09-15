// bound_method_weak_shapes.xc — a stored `^` auto-zeroes in EVERY storage kind.
//
// A `^` is an auto-zeroing slot wherever it is stored. Ivars and locals were
// covered (bound_method_weak, bound_method_local_weak); these two were not, and
// both were silent use-after-frees of exactly the gap-F shape — the storage had
// its link words, but nothing ever LINKED it, so the guard stayed true and the
// action fired through freed memory:
//
//   T1  a `^` GLOBAL
//   T2  a `^` ARRAY ELEMENT
//
// (A `^` inside a plain struct is a compile error — a struct's member access
// indexes its fields directly, so the hidden link words would shift every index.
// Use a class.)
#import "Stdio.xc"

typedef u16 act_t(void);

class C
{
    u16  v;
    void init(void)    { v = (u16)9; }
    u16  g(void)       { return v; }
    void dealloc(void) { Stdio.printf("died\n"); }
}

act_t^ gAction;                        // T1: a `^` global

void main(void)
{
    // T1: global — must go falsy when its receiver dies.
    {
        C* c = new C();
        gAction = &c.g;
        Stdio.printf("g-alive=%d\n", (u16)(gAction ? (u16)1 : (u16)0));
    }
    Stdio.printf("g-dead=%d\n", (u16)(gAction ? (u16)1 : (u16)0));

    // T2: array element — same.
    act_t^ arr[2];
    {
        C* c2 = new C();
        arr[0] = &c2.g;
        Stdio.printf("a-alive=%d\n", (u16)(arr[0] ? (u16)1 : (u16)0));
    }
    Stdio.printf("a-dead=%d\n", (u16)(arr[0] ? (u16)1 : (u16)0));
}
