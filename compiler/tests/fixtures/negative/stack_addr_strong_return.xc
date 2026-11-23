// Returning the address of a stack instance from a function with a strong
// class-pointer return: the instance ends with the function, and the
// caller's retain would land on a header it never had (#604).
// xtc: error "returning '&y', the address of a stack instance that ends with this function; return the instance by value ('P') or allocate it with new"

class P : Object { i32 a; i32 b; }

P* make(void)
    {
    P y;
    y.a = 2;
    return &y;
    }

i32 main(void)
    {
    P* r = make();
    return r.a;
    }
