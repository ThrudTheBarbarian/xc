// A strong ivar assigned the address of a stack instance retains through a
// header the instance does not have, and outlives it (#604).
// xtc: error "'&y' is the address of a stack instance, which has no reference count, so the strong 'P*' field 'last' cannot hold it; declare 'last' as 'weak:P* last', which does not retain it, or use y directly"

class P : Object { i32 a; i32 b; }

class Holder : Object
    {
    P* last;
    void keep(void)
        {
        P y;
        y.a = 2;
        last = &y;
        }
    }

i32 main(void)
    {
    Holder* h = new Holder();
    h.keep();
    return 0;
    }
