// A class instance held by value inside a stack instance has no header
// either, so its address cannot go into a strong pointer (#604).
// xtc: error "'&o.inner' is the address of a stack instance, which has no reference count, so a strong 'P*' cannot hold it; declare it 'weak:P* r = &o.inner;', which does not retain it, or use o.inner directly"

class P : Object { i32 a; i32 b; }
class Outer : Object { i32 k; P inner; }

i32 main(void)
    {
    Outer o;
    o.inner.a = 2;
    P* r = &o.inner;
    return r.a;
    }
