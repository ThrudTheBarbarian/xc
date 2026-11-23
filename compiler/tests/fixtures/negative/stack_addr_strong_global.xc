// A strong global assigned the address of a stack instance retains through
// a header the instance does not have, and outlives it (#604).
// xtc: error "'&y' is the address of a stack instance, which has no reference count, so the strong 'P*' global 'gLast' cannot hold it; declare 'gLast' as 'weak:P* gLast', which does not retain it, or use y directly"

class P : Object { i32 a; i32 b; }

P* gLast;

void keep(void)
    {
    P y;
    y.a = 2;
    gLast = &y;
    }

i32 main(void)
    {
    keep();
    return 0;
    }
