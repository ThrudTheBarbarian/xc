// A strong class pointer initialised from the address of a stack instance
// would retain through a header the instance does not have (#604): the
// count lands on the word before it, often the previous instance's last
// field. weak: does not retain.
// xtc: error "'&y' is the address of a stack instance, which has no reference count, so a strong 'P*' cannot hold it; declare it 'weak:P* r = &y;', which does not retain it, or use y directly"

class P : Object { i32 a; i32 b; }

i32 main(void)
    {
    P y;
    y.a = 2;
    P* r = &y;
    return r.a;
    }
