// Assigning the address of a stack instance to a strong local retains
// through a header the instance does not have (#604).
// xtc: error "'&y' is the address of a stack instance, which has no reference count, so the strong 'P*' local 'r' cannot hold it; declare 'r' as 'weak:P* r', which does not retain it, or use y directly"

class P : Object { i32 a; i32 b; }

i32 main(void)
    {
    P y;
    y.a = 2;
    P* r = nil;
    r = &y;
    return r.a;
    }
