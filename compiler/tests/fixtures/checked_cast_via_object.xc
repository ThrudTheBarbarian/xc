// checked_cast_via_object.xc — what remains legal around a raw `pointer`.
//
// `(T* ?)p` from a raw `pointer` is refused (checked_cast_from_pointer_refused.xc):
// a pointer need not hold an object. Saying that it does, by casting to
// Object* first, makes the check real again; and a plain `(T*)p` is still an
// unchecked reinterpretation, as it always was.
//   T1  (B* ?)(Object*)p, p holds an A   — null.
//   T2  (A* ?)(Object*)p, p holds an A   — the object.
//   T3  (A*)p                            — unchecked, the object.
//   T4  (A* ?)(Object*)p, p is null      — stays null.

#import "Stdio.xc"

class A : Object { i32 a; }
class B : Object { i32 b; i32 more[8]; }

i32 main(void)
{
    A* x = new A();
    x.a = 7;
    pointer p = (pointer)x;
    B* b = (B* ?)(Object*)p;
    Stdio.printf("T1 %s\n", b == (B*)0 ? "null" : "non-null");
    A* a = (A* ?)(Object*)p;
    Stdio.printf("T2 %d\n", a == (A*)0 ? -1 : a.a);
    A* u = (A*)p;
    Stdio.printf("T3 %d\n", u.a);
    pointer z = (pointer)0;
    A* n = (A* ?)(Object*)z;
    Stdio.printf("T4 %s\n", n == (A*)0 ? "null" : "non-null");
    return 0;
}
