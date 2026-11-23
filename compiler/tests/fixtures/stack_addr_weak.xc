// stack_addr_weak.xc — a weak pointer to a stack instance (#604).
//
// A stack instance has no header, so no reference count. A strong pointer to
// one is refused (tests/fixtures/negative/stack_addr_strong_*); a weak one
// does not retain, so it may hold the address.
//
//   T1  `weak:P* r = &y;` reads y's fields, and the instance declared before
//       y keeps its last field (a retain used to add 1 to it: `2 2 2`)
//   T2  a weak local assigned `&y` in an inner block reads that instance
//   T3  heap instances and the address of a field that is not an instance
//       are unaffected

#import "Stdio.xc"

class P : Object { i32 a; i32 b; }

i32 main(void)
    {
    P x; x.a = 1; x.b = 1;
    P y; y.a = 2; y.b = 2;
    weak:P* r = &y;
    Stdio.printf("%d %d %d\n", x.b, y.a, r.a);

    weak:P* w = nil;
        {
        P z; z.a = 5; z.b = 6;
        w = &z;
        Stdio.printf("%d %d\n", w.a, w.b);
        }
    Stdio.printf("%d %d\n", x.a, x.b);

    P* h = new P();
    h.a = 7;
    P* h2 = h;
    i32* pa = &y.b;
    *pa = 9;
    Stdio.printf("%d %d %d\n", h2.a, y.b, r.b);
    return 0;
    }
